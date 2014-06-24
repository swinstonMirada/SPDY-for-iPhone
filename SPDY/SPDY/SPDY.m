//
//  SPDY.m
//  SPDY library implementation.
//
//  Created by Jim Morrison on 1/31/12.
//  Copyright 2012 Twist Inc.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

// http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "SPDY.h"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CFNetwork/CFNetwork.h>

#include <assert.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netdb.h>

#include "openssl/ssl.h"
#include "spdylay/spdylay.h"

#import "SpdySession.h"
#import "SpdyInputStream.h"
#import "SpdyStream.h"
#import "SpdyUrlConnection.h"
#import "SpdySessionKey.h"

// The shared spdy instance.
static SPDY *spdy = NULL;
NSString *kSpdyErrorDomain = @"SpdyErrorDomain";
NSString *kOpenSSLErrorDomain = @"OpenSSLErrorDomain";

static int select_next_proto_cb(SSL *ssl,
                                unsigned char **out, unsigned char *outlen,
                                const unsigned char *in, unsigned int inlen,
                                void *arg) {
    SpdySession *sc = (SpdySession *)SSL_get_app_data(ssl);
    int spdyVersion = spdylay_select_next_protocol(out, outlen, in, inlen);
    if (spdyVersion > 0) {
        sc.spdyVersion = spdyVersion;
        sc.spdyNegotiated = YES;
    }
    
    return SSL_TLSEXT_ERR_OK;
}

@interface SpdyLogImpl : NSObject<SpdyLogger>
@end

@implementation SpdyLogImpl
- (void)writeSpdyLog:(NSString *)format file:(const char *)file line:(int)line, ... {
    NSLog(@"[%s:%d]", file, line);

    va_list args;
    va_start(args, line);
    NSLogv(format, args);
    va_end(args);
}
@end

@interface SPDY ()
- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(RequestCallback *)delegate body:(NSInputStream *)body;
+ (SpdyNetworkStatus)reachabilityStatusForHost:(NSString *)host;

- (void)setUpSslCtx;

@property (nonatomic, retain) NSMutableDictionary *sessions;
@property (nonatomic, assign) SSL_CTX *ssl_ctx;

@end

@implementation SPDY

@synthesize logger = _logger;
@synthesize sessions = _sessions;
@synthesize ssl_ctx =  _ssl_ctx;

// This logic was stripped from Apple's Reachability.m sample application.
+ (SpdyNetworkStatus)networkStatusForReachabilityFlags:(SCNetworkReachabilityFlags)flags {
    // Host not reachable.
    if ((flags & kSCNetworkReachabilityFlagsReachable) == 0)
        return kSpdyNotReachable;
    
    // Host reachable by WWAN.
    if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN)
        return kSpdyReachableViaWWAN;
    
    // Host reachable and no connection is required. Assume wifi.
    if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0)
        return kSpdyReachableViaWiFi;
    
    // Host reachable. Connection is on-demand or on-traffic. No user intervention needed. Assume wifi.
    if (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand) != 0) ||
        ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)) {
        if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0)
            return kSpdyReachableViaWiFi;
    }
    
    return kSpdyNotReachable;
}

+ (SpdyNetworkStatus)reachabilityStatusForHost:(NSString *)host {	
    SpdyNetworkStatus status = kSpdyNotReachable;
	SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithName(NULL, [host UTF8String]);
	if (ref) {
        SCNetworkReachabilityFlags flags = 0;
        if (SCNetworkReachabilityGetFlags(ref, &flags))
            status = [self networkStatusForReachabilityFlags:flags];
        
        CFRelease(ref);
    }
    return status;
}

- (SpdySession *)getSession:(NSURL *)url withError:(NSError **)error {
    assert(error != NULL);
    SpdySessionKey *key = [[[SpdySessionKey alloc] initFromUrl:url] autorelease];
    SpdySession *session = [self.sessions objectForKey:key];
    SPDY_LOG(@"Looking up %@, found %@", key, session);
    SpdyNetworkStatus currentStatus = [self.class reachabilityStatusForHost:key.host];
    SSL_SESSION *oldSslSession =  NULL;
    if (session != nil && ([session isInvalid] || currentStatus != session.networkStatus)) {
        SPDY_LOG(@"Resetting %@ because invalid: %i or %d != %d", session, [session isInvalid], currentStatus, session.networkStatus);
        [session resetStreamsAndGoAway];
        oldSslSession = [session getSslSession];
        [self.sessions removeObjectForKey:key];
        session = nil;
    }
    if (session == nil) {
        session = [[[SpdySession alloc] init:self.ssl_ctx oldSession:oldSslSession] autorelease];
        *error = [session connect:url];
        if (*error != nil) {
            SPDY_LOG(@"Could not connect to %@ because %@", url, *error);
            return nil;
        }
        SPDY_LOG(@"Adding %@ to sessions (size = %u)", key, (uint32_t)[self.sessions count] + 1);
        currentStatus = [self.class reachabilityStatusForHost:key.host];
        session.networkStatus = currentStatus;
        [self.sessions setObject:session forKey:key];
        [session addToLoop];
    }
    return session;
}

- (void)fetch:(NSString *)url delegate:(RequestCallback *)delegate {
    NSURL *u = [NSURL URLWithString:url];
    if (u == nil || u.host == nil) {
        NSError *error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
        [delegate onError:error];
        return;
    }
    NSError *error;
    SpdySession *session = [self getSession:u withError:&error];
    if (session == nil) {
        [delegate onError:error];
        return;
    }
    [session fetch:u delegate:delegate];
}

- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(RequestCallback *)delegate {
    [self fetchFromMessage:request delegate:delegate body:nil];
}

- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(RequestCallback *)delegate body:(NSInputStream *)body {
    CFURLRef url = CFHTTPMessageCopyRequestURL(request);
    NSError *error;
    SpdySession *session = [self getSession:(NSURL *)url withError:&error];
    if (session == nil) {
        [delegate onError:error];
    } else {
        [session fetchFromMessage:request delegate:delegate body:body];
    }
    CFRelease(url);    
}

- (void)fetchFromRequest:(NSURLRequest *)request delegate:(RequestCallback *)delegate {
    NSURL *url = [request URL];
    NSError *error;
    SpdySession *session = [self getSession:(NSURL *)url withError:&error];
    if (session == nil) {
        [delegate onError:error];
    } else {
        [session fetchFromRequest:request delegate:delegate];
    }
}

- (NSInteger)closeAllSessions {
    NSInteger cancelledRequests = 0;
    NSEnumerator *enumerator = [self.sessions objectEnumerator];
    SpdySession *session;
    
    while ((session = (SpdySession *)[enumerator nextObject])) {
        cancelledRequests += [session resetStreamsAndGoAway];
    }
    [self.sessions removeAllObjects];
    return cancelledRequests;
}

- (NSInteger)closeAllSessionsForURL:(NSURL *)url {
    NSInteger cancelledRequests = 0;
    SpdySessionKey *urlKey = [[[SpdySessionKey alloc] initFromUrl:url] autorelease];
    SpdySession *session = [self.sessions objectForKey:urlKey];
    if (session != nil) {
        cancelledRequests = [session resetStreamsAndGoAway];
        [self.sessions removeObjectForKey:urlKey];
    }
    return cancelledRequests;
    
}

- (SPDY *)init {
    self = [super init];
    if (self) {
        self.logger = [[[SpdyLogImpl alloc] init] autorelease];
        self.sessions = [[NSMutableDictionary alloc] init];
        [self setUpSslCtx];
    }
    return self;
}

- (void)dealloc {
    [_logger release];
    [_sessions release];
    SSL_CTX_free(_ssl_ctx);
    [super dealloc];
}

- (void)setUpSslCtx {
    self.ssl_ctx = SSL_CTX_new(SSLv23_client_method());
    assert(self.ssl_ctx);
    
    /* Disable SSLv2 and enable all workarounds for buggy servers */
    SSL_CTX_set_options(self.ssl_ctx, SSL_OP_ALL|SSL_OP_NO_SSLv2);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_AUTO_RETRY);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_ENABLE_PARTIAL_WRITE);
    SSL_CTX_set_next_proto_select_cb(self.ssl_ctx, select_next_proto_cb, self);
    SSL_CTX_set_session_cache_mode(self.ssl_ctx, SSL_SESS_CACHE_CLIENT);
}


+ (SPDY *)sharedSPDY {
    if (spdy == NULL) {
        SSL_library_init();
        spdy = [[SPDY alloc] init];
        [SpdyStream staticInit];
    }
    return spdy;
}

#pragma mark - NSURLConnection related methods.

// These methods are object methods so that sharedSpdy is called before registering SpdyUrlConnection with NSURLConnection.
- (void)registerForNSURLConnection {
    [SpdyUrlConnection registerSpdy];
}

- (void)registerForNSURLConnectionWithCallback:(id <SpdyUrlConnectionCallback>)callback {
    [SpdyUrlConnection registerSpdyWithCallback:callback];
}

- (BOOL)isSpdyRegistered {
    return [SpdyUrlConnection isRegistered];
}

- (BOOL)isSpdyRegisteredForUrl:(NSURL *)url {
    return [SpdyUrlConnection isRegistered] && [SpdyUrlConnection canInitWithUrl:url];
}

- (void)unregisterForNSURLConnection {
    [SpdyUrlConnection unregister];
}
@end

@implementation RequestCallback

- (void)onRequestBytesSent:(NSInteger)bytesSend {
    
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
    return length;
}

- (void)onResponseHeaders:(CFHTTPMessageRef)headers {
}

- (void)onError:(NSError *)error {
    
}

- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier {
    
}

- (void)onStreamClose {
    
}

- (void)onConnect:(id<SpdyRequestIdentifier>)url {
    
}
@end

@interface BufferedCallback ()

@property (nonatomic, assign) CFHTTPMessageRef headers;
@property (nonatomic, assign) CFMutableDataRef body;
@end

@implementation BufferedCallback

@synthesize url = _url;
@synthesize headers = _headers;
@synthesize body = _body;

- (id)init {
    self = [super init];
    self.url = nil;
    _headers = NULL;
    self.body = CFDataCreateMutable(NULL, 0);
    return self;
}

- (void)dealloc {
    [_url release];
    CFRelease(_body);
    CFRelease(_headers);
    [super dealloc];
}

- (void)setHeaders:(CFHTTPMessageRef)h {
    CFHTTPMessageRef oldRef = _headers;
    _headers = CFHTTPMessageCreateCopy(NULL, h);
    if (oldRef)
        CFRelease(oldRef);
}

- (void)onConnect:(id<SpdyRequestIdentifier>)u {
    self.url = u.url;
}

-(void)onResponseHeaders:(CFHTTPMessageRef)h {
    self.headers = h;
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
    CFDataAppendBytes(self.body, bytes, length);
    return length;
}

- (void)onStreamClose {
    CFHTTPMessageSetBody(self.headers, self.body);
    [self onResponse:self.headers];
}

- (void)onResponse:(CFHTTPMessageRef)response {
    
}

- (void)onError:(NSError *)error {
    
}
@end

// Create a delegate derived class of RequestCallback.  Create a context struct.
// Convert this to an objective-C object that derives from RequestCallback.
@interface _SpdyCFStream : RequestCallback {
    CFWriteStreamRef writeStreamPair;  // read() will write into writeStreamPair.
    unsigned long long requestBytesWritten;
};

@property (assign) BOOL opened;
@property (assign) int error;
@property (retain) SpdyInputStream *readStreamPair;
@end


@implementation _SpdyCFStream

@synthesize opened;
@synthesize error;
@synthesize readStreamPair;

- (_SpdyCFStream *)init:(CFAllocatorRef)a {
    self = [super init];
    
    CFReadStreamRef baseReadStream;
    CFStreamCreateBoundPair(a, &baseReadStream, &writeStreamPair, 16 * 1024);
    self.readStreamPair = [[[SpdyInputStream alloc] init:(NSInputStream *)baseReadStream] autorelease];
    self.opened = NO;
    requestBytesWritten = 0;
    return self;
}

- (void)dealloc {
    self.readStreamPair.requestId = nil;
    if ([self.readStreamPair streamStatus] != NSStreamStatusClosed) {
        [self.readStreamPair close];
    }
    if (CFWriteStreamGetStatus(writeStreamPair) != kCFStreamStatusClosed) {
        CFWriteStreamClose(writeStreamPair);
    }
    CFRelease(writeStreamPair);
    self.readStreamPair = nil;
    [super dealloc];
}

- (void)setResponseHeaders:(CFHTTPMessageRef)h {
}

// Methods that implementors should override.
- (void)onConnect:(id<SpdyRequestIdentifier>)requestId {
    [self.readStreamPair setRequestId:requestId];
    CFWriteStreamOpen(writeStreamPair);
    self.opened = YES;
}

- (void)onRequestBytesSent:(NSInteger)bytesSend {
    requestBytesWritten += bytesSend;
    CFNumberRef totalBytes = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &requestBytesWritten);
    CFReadStreamSetProperty((CFReadStreamRef)readStreamPair, kCFStreamPropertyHTTPRequestBytesWrittenCount, totalBytes);
    CFRelease(totalBytes);
}

- (void)onResponseHeaders:(CFHTTPMessageRef)headers {
    CFReadStreamSetProperty((CFReadStreamRef)readStreamPair, kCFStreamPropertyHTTPResponseHeader, headers);
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
    // TODO(jim): Ensure that any errors from write() get transfered to the SpdyStream.
    return CFWriteStreamWrite(writeStreamPair, bytes, length);
}

- (void)onStreamClose {
    self.opened = NO;
    CFWriteStreamClose(writeStreamPair);
}

- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier {
    self.readStreamPair.error = [NSError errorWithDomain:kSpdyErrorDomain code:kSpdyConnectionNotSpdy userInfo:[NSDictionary dictionaryWithObject:[identifier url] forKey:@"url"]];
}

- (void)onError:(NSError *)error_code {
    self.readStreamPair.error = error_code;
    self.opened = NO;
}

@end

CFReadStreamRef SpdyCreateSpdyReadStream(CFAllocatorRef alloc, CFHTTPMessageRef requestHeaders, CFReadStreamRef requestBody) {
    _SpdyCFStream *ctx = [[[_SpdyCFStream alloc] init:alloc] autorelease];
    if (ctx) {
        SPDY *spdy = [SPDY sharedSPDY];
        [spdy fetchFromMessage:requestHeaders delegate:ctx body:(NSInputStream *)requestBody];
        return (CFReadStreamRef)[[ctx readStreamPair] retain];
     }
     return NULL;
}
                         

