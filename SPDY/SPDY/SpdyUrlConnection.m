//
//  SpdyUrlConnection.m
//  NOTE: iOS makes a copy of the return value of responseWithURL:andMessage:withRequestBytes, so the original type is
//  lost.
//
//  Created by Jim Morrison on 4/2/12.
//  Copyright (c) 2012 Twist Inc.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

// http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "SpdyUrlConnection.h"
#import "SpdyHTTPResponse.h"
#import "SpdyCallback.h"
#import "SPDY.h"
#include "zlib.h"

// This is actually a dictionary of sets.  The first set is the host names, the second is a set of ports.
static NSMutableDictionary *enabledHosts;
static NSMutableDictionary *disabledHosts;

// The delegate is called each time on a url to determine if a request should use spdy.
static id <SpdyUrlConnectionCallback> globalCallback;

@interface SpdyUrlConnectionRequestCallback : SpdyCallback
- (id)initWithConnection:(SpdyUrlConnection *)protocol;
@property (strong) SpdyUrlConnection *protocol;
@property (assign) NSInteger requestBytesSent;
@property (nonatomic, assign) BOOL needUnzip;
@property (nonatomic, assign) z_stream zlibContext;
@end

@implementation SpdyUrlConnectionRequestCallback
@synthesize protocol = _protocol;
@synthesize requestBytesSent = _requestBytesSent;
@synthesize needUnzip = _needUnzip;
@synthesize zlibContext = _zlibContext;

- (id)initWithConnection:(SpdyUrlConnection *)protocol {
    self = [super init];
    if (self != nil) {
        self.protocol = protocol;
    }
    return self;
}

- (void)dealloc {
    if (self.needUnzip)
        inflateEnd(&_zlibContext);
}

- (void)onConnect:(id<SpdyRequestIdentifier>)spdyId {
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onConnect: %@", self.protocol, spdyId);
    self.protocol.spdyIdentifier = spdyId;
    if (self.protocol.cancelled) {
        [spdyId close];
    }
}

- (void)onError:(NSError *)error {
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onError: %@, %@", self.protocol, error, self.protocol.spdyIdentifier);
    if (!self.protocol.cancelled) {
        [[self.protocol client] URLProtocol:self.protocol didFailWithError:error];
    }
}

- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier {
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onNotSpdyError: %@", self.protocol, identifier);
    NSURL *url = [identifier url];
    [SpdyUrlConnection disableUrl:url];
    NSError *error = [NSError errorWithDomain:kSpdyErrorDomain code:kSpdyConnectionNotSpdy userInfo:nil];
    [[self.protocol client] URLProtocol:self.protocol didFailWithError:error];    
}

- (void)onRequestBytesSent:(NSInteger)bytesSend {
  SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onRequestBytesSent: %ld", self.protocol, (long)bytesSend);
    // The updated byte count should be sent, but the URLProtocolClient doesn't have a method to do that.
    //[[self.protocol client] URLProtocol:self.protocol didSendBodyData:bytesSend];
    self.requestBytesSent += bytesSend;
}

- (void)onResponseHeaders:(CFHTTPMessageRef)headers {
    NSHTTPURLResponse *response = [SpdyHTTPResponse responseWithURL:[self.protocol.spdyIdentifier url] andMessage:headers withRequestBytes:self.requestBytesSent];
    if ([[response.allHeaderFields objectForKey:@"Content-Encoding"] hasPrefix:@"gzip"]) {
        self.needUnzip = YES;
        memset(&_zlibContext, 0, sizeof(_zlibContext));
        inflateInit2(&_zlibContext, 16+MAX_WBITS);
    }
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onResponseHeaders: %@", self.protocol, [response allHeaderFields]);

    [[self.protocol client] URLProtocol:self.protocol didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onResponseData: %lu", self.protocol, length);
    if (self.needUnzip) {
        _zlibContext.avail_in = (int32_t)length;
        _zlibContext.next_in = (uint8_t *)bytes;
        while (self.zlibContext.avail_in > 0) {
            NSInteger bytesHad = self.zlibContext.total_out;
            NSMutableData *inflateData = [NSMutableData dataWithCapacity:4096];
            _zlibContext.next_out = [inflateData mutableBytes];
            _zlibContext.avail_out = 4096;
            NSInteger inflatedBytes = self.zlibContext.total_out - bytesHad;
#ifdef CONF_Debug	    
            int inflateStatus = inflate(&_zlibContext, Z_SYNC_FLUSH);
            SPDY_LOG(@"Unzip status: %d, inflated %ld bytes", inflateStatus, (long)inflatedBytes);
#endif
            NSData *data = [NSData dataWithBytes:[inflateData bytes] length:inflatedBytes];
            [[self.protocol client] URLProtocol:self.protocol didLoadData:data];
        }
    } else {
        NSData *data = [NSData dataWithBytes:bytes length:length];
        [[self.protocol client] URLProtocol:self.protocol didLoadData:data];
    }
    return length;
}

- (void)onStreamClose {
    SPDY_DEBUG_LOG(@"SpdyURLConnection: %@ onStreamClose", self.protocol);
    self.protocol.closed = YES;
    self.protocol.spdyIdentifier = nil;
    [[self.protocol client] URLProtocolDidFinishLoading:self.protocol];
}

@end

@interface SpdyUrlConnection ()
@property (assign) BOOL cancelled;
@end

@implementation SpdyUrlConnection
@synthesize spdyIdentifier = _spdyIdentifier;
@synthesize cancelled = _cancelled;
@synthesize closed = _closed;

+ (void)registerSpdy {
    [self registerSpdyWithCallback:nil];
}

+ (void)registerSpdyWithCallback:(id <SpdyUrlConnectionCallback>)callback {
    enabledHosts = [[NSMutableDictionary alloc] init];
    disabledHosts = [[NSMutableDictionary alloc] init];
    globalCallback = callback;
    [NSURLProtocol registerClass:[SpdyUrlConnection class]];    
}

+ (BOOL)isRegistered {
    return disabledHosts != nil;
}

+ (void)unregister {
    [NSURLProtocol unregisterClass:[SpdyUrlConnection class]];
    enabledHosts = nil;
    disabledHosts = nil;
    globalCallback = nil;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [SpdyUrlConnection canInitWithUrl:[request URL]];
}

+ (BOOL)canInitWithUrl:(NSURL *)url {
    NSSet *ports1 = [disabledHosts objectForKey:[url host]];
    if(ports1 != nil) {
        NSNumber *port = [url port];
        if(port == nil)
            port = [NSNumber numberWithInt:443];
        if([ports1 containsObject:port])
            return NO;
    }
    NSSet *ports = [enabledHosts objectForKey:[url host]];
    if (ports != nil) {
        NSNumber *port = [url port];
        if (port == nil)
            port = [NSNumber numberWithInt:443];
        if ([ports containsObject:port])
            return YES;
    }
    return NO;
}

+ (void)enableUrl:(NSURL *)url {
    NSMutableSet *ports = [enabledHosts objectForKey:[url host]];
    if (ports == nil) {
        ports = [NSMutableSet set];
        [enabledHosts setObject:ports forKey:[url host]];
    }
    SPDY_LOG(@"Enabling spdy for %@", url);
    if ([url port] == nil) {
        [ports addObject:[NSNumber numberWithInt:80]];
        [ports addObject:[NSNumber numberWithInt:443]];
    } else {
        [ports addObject:[url port]];
    }
}

+ (void)disableUrl:(NSURL *)url {
    NSMutableSet *ports = [disabledHosts objectForKey:[url host]];
    if (ports == nil) {
        ports = [NSMutableSet set];
        [disabledHosts setObject:ports forKey:[url host]];
    }
    SPDY_LOG(@"Disabling spdy for %@", url);
    if ([url port] == nil) {
        [ports addObject:[NSNumber numberWithInt:80]];
        [ports addObject:[NSNumber numberWithInt:443]];
    } else {
        [ports addObject:[url port]];
    }
}

// This could be a good place to remove the connection headers.
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}


- (void)startLoading {
    SPDY_DEBUG_LOG(@"Start loading SpdyURLConnection: %@ with URL: %@", self, [[self request] URL])
    SpdyUrlConnectionRequestCallback *delegate = [[SpdyUrlConnectionRequestCallback alloc] initWithConnection:self];
    [[SPDY sharedSPDY] fetchFromRequest:[self request] delegate:delegate];
}

- (void)stopLoading {
    SPDY_DEBUG_LOG(@"Stop loading SpdyURLConnection: %@ with URL: %@", self, [[self request] URL])
    if (self.closed)
        return;
    self.cancelled = YES;
    if (self.spdyIdentifier != nil) {
        SPDY_LOG(@"Cancelling request for %@", self.spdyIdentifier);
        [self.spdyIdentifier close];
    }
}

@end
