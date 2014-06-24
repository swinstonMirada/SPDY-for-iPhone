//
//  SpdyStream.m
//  A class representing a SPDY stream.  This class is responsible for converting to a CFHTTPMessage.
//
//  Created by Jim Morrison on 2/7/12.
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

#import "SpdyStream.h"
#import "SpdyCallback.h"
#import "SpdyPushCallback.h"
#import "SpdySession.h"

static NSSet *headersNotToCopy = nil;
NSString *kSpdyTimeoutHeader = @"x-spdy-timeout";

@interface SpdyStream ()
- (void)fixArena:(NSInteger)length;
- (const char *)copyString:(NSString *)str;
- (NSMutableData *)createArena:(NSInteger)capacity;
- (int)serializeUrl:(NSURL *)url withMethod:(NSString *)method withVersion:(NSString *)version;
- (int)serializeHeadersDict:(NSDictionary *)headers fromIndex:(int)index;
- (CFHTTPMessageRef)newResponseMessage:(const char **)nameValuePairs;

@property (strong) NSMutableData *stringArena;
@property (strong) NSURL *url;

@end

@implementation SpdyStream {
    NSMutableArray *arenas;
    NSInteger arenaCapacity;
}

@synthesize nameValues;
@synthesize url = _url;
@synthesize body;
@synthesize delegate;
@synthesize parentSession;
@synthesize streamId;
@synthesize stringArena;

+ (void)staticInit {
    if (headersNotToCopy == nil) {
        headersNotToCopy = [[NSSet alloc] initWithObjects:@"host", @"connection", kSpdyTimeoutHeader, nil];
    }
}

- (id)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    SPDY_LOG(@"%p init", self);
    streamClosed = NO;
    self.body = nil;
    self.streamId = -1;
    arenas = nil;
    arenaCapacity = -1;
    self.stringArena = nil;
    return self;
}

- (void)dealloc {
    SPDY_LOG(@"%p dealloc", self);
    free(nameValues);
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@: %@, streamId=%ld", [super description], self.url, (long)self.streamId];
}

- (CFHTTPMessageRef)newResponseMessage:(const char **)nameValuePairs {
    CFIndex statusCode = -1;
    CFStringRef statusDescription = CFSTR("");
    CFStringRef httpVersion = NULL;
    while (*nameValuePairs != NULL && *(nameValuePairs + 1) != NULL) {
        if (strcmp(nameValuePairs[0], ":status") == 0) {
            char *description;
            statusCode = strtol(nameValuePairs[1], &description, 10);
            if (statusDescription != NULL)
                CFRelease(statusDescription);
            statusDescription = CFStringCreateWithCString(kCFAllocatorSystemDefault, description, kCFStringEncodingUTF8);
        }
        if (nameValuePairs[0] && strcmp(nameValuePairs[0], ":version") == 0) {
            if (httpVersion != NULL)
                CFRelease(httpVersion);
            httpVersion = CFStringCreateWithCString(kCFAllocatorSystemDefault, nameValuePairs[1], kCFStringEncodingASCII);
        }
        nameValuePairs += 2;
        if (statusCode > 0 && httpVersion != NULL)
            break;
    }
    CFHTTPMessageRef response = NULL;
    if (statusCode > 0 && httpVersion)
        response = CFHTTPMessageCreateResponse(kCFAllocatorSystemDefault, statusCode, statusDescription, httpVersion);
    if (statusDescription != NULL)
        CFRelease(statusDescription);
    if (httpVersion != NULL)
        CFRelease(httpVersion);
    return response;
}

- (void)parseHeaders:(const char **)nameValuePairs {
    CFHTTPMessageRef response = [self newResponseMessage:nameValuePairs];
    if (response == NULL) {
        [delegate onError:[NSError errorWithDomain:kSpdyErrorDomain code:kSpdyInvalidResponseHeaders userInfo:nil]];
        return;
    }
    while (*nameValuePairs != NULL && *(nameValuePairs+1) != NULL) {
        CFStringRef key = CFStringCreateWithCString(NULL, nameValuePairs[0], kCFStringEncodingUTF8);
        CFStringRef value = CFStringCreateWithCString(NULL, nameValuePairs[1], kCFStringEncodingUTF8);
        nameValuePairs += 2;
        if (key != NULL) {
            if (value != NULL) {
                CFHTTPMessageSetHeaderFieldValue(response, key, value);
                CFRelease(value);
            }
            CFRelease(key);
        } else if (value != NULL) {
            CFRelease(value);            
        }
    }
    assert(CFHTTPMessageAppendBytes(response, (const UInt8 *)"\r\n", 2));
    [delegate onResponseHeaders:response];
    CFRelease(response);
}

- (size_t)writeBytes:(const uint8_t *)bytes len:(size_t)length {
    return [delegate onResponseData:bytes length:length];
}

- (void)closeStream {
    SPDY_LOG(@"%p closeStream", self);

    if (streamClosed != YES) {
        streamClosed = YES;
        [delegate onStreamClose];
    }
}

- (void)cancelStream {
    SPDY_LOG(@"%p cancelStream", self);
    streamClosed = YES;
    [delegate onError:[NSError errorWithDomain:kSpdyErrorDomain code:kSpdyRequestCancelled userInfo:nil]];
}

- (void)close {
    SPDY_LOG(@"%p close", self);
    [self.parentSession cancelStream:self];
}

- (void)notSpdyError {
    [delegate onNotSpdyError:self];
}

- (void)connectionError {
    SPDY_LOG(@"connectionError")
    [delegate onError:[NSError errorWithDomain:kSpdyErrorDomain code:kSpdyConnectionFailed userInfo:nil]];
}

- (NSMutableData *)createArena:(NSInteger)capacity {
    arenaCapacity = capacity;
    return [NSMutableData dataWithCapacity:capacity];
}

- (void)fixArena:(NSInteger)length {
    if ([self.stringArena length] + length > arenaCapacity) {
        SPDY_LOG(@"Adding an arena. %u > %ld", (uint32_t)([self.stringArena length] + length), (long)arenaCapacity);
        if (arenas == nil) {
            arenas = [[NSMutableArray alloc] initWithCapacity:2];
        }
        [arenas addObject:self.stringArena];

        NSInteger newCapacity = length > arenaCapacity ? length : arenaCapacity;
        self.stringArena = [self createArena:newCapacity];
    }
}

- (const char *)copyString:(NSString *)str {
    const char *utf8 = [str UTF8String];
    unsigned long length = strlen(utf8) + 1;
    [self fixArena:length];
    NSInteger arenaLength = [self.stringArena length];
    [self.stringArena appendBytes:utf8 length:length];
    return (const char*)[self.stringArena mutableBytes] + arenaLength;
}

- (void)serializeHeaders:(CFHTTPMessageRef)msg {
    CFDictionaryRef d = CFHTTPMessageCopyAllHeaderFields(msg);
    CFURLRef url = CFHTTPMessageCopyRequestURL(msg);
    CFStringRef method = CFHTTPMessageCopyRequestMethod(msg);
    CFStringRef version = CFHTTPMessageCopyVersion(msg);
    CFIndex count = CFDictionaryGetCount(d);

    self.nameValues = malloc((count * 2 + 6*2 + 1) * sizeof(const char *));
    
    int index = [self serializeUrl:(__bridge NSURL *)url withMethod:(__bridge NSString *)method withVersion:(__bridge NSString *)version];
    index = [self serializeHeadersDict:(__bridge NSDictionary *)d fromIndex:index];
    self.nameValues[index] = NULL;

    CFRelease(url);
    CFRelease(version);
    CFRelease(method);
    CFRelease(d);
}

// Assumes self.nameValues is at least 12 elements long.
- (int)serializeUrl:(NSURL *)url withMethod:(NSString *)method withVersion:(NSString *)version {
    self.url = url;
    const char** nv = self.nameValues;
    nv[0] = ":method";
    nv[1] = [self copyString:method];
    nv[2] = ":scheme";
    nv[3] = [self copyString:[url scheme]];
    nv[4] = ":path";
    const char* pathPlus = [self copyString:[url resourceSpecifier]];
    const char* host = [self copyString:[url host]];
    unsigned long portLength = [url port] ? [[[url port] stringValue] length] + 1 : 0;
    const char * path = pathPlus + strlen(host) + 2 + portLength;
    if(strlen(path) == 0) path = "/"; // don't send an empty path
    nv[5] = path;
    SPDY_LOG(@"PATH IS '%s'", nv[5]);
    nv[6] = ":host";
    nv[7] = host;
    nv[8] = ":version";
    nv[9] = [self copyString:version];


    SPDY_LOG(@"Name value pairs for SYN_STREAM:");
    for(int i = 0 ; i < 5 ; i++) {
      SPDY_LOG(@"\t%s => %s", nv[i*2], nv[i*2+1]);
    }

    return 10;
}

// Returns the next index.
- (int)serializeHeadersDict:(NSDictionary *)headers fromIndex:(int)index {
    if (headers == nil) {
        return index;
    }

    int nameValueIndex = index;
    const char **nv = self.nameValues;
    for (NSString *k in headers) {
        NSString *key = [k lowercaseString];
        if (![headersNotToCopy containsObject:key]) {
            NSString *value = [headers objectForKey:k];
            nv[nameValueIndex] = [self copyString:key];
            nv[nameValueIndex + 1] = [self copyString:value];
            nameValueIndex += 2;
        } else if ([kSpdyTimeoutHeader isEqualToString:key]) {
            self.streamTimeoutInterval = [[headers objectForKey:key] doubleValue];
        }
    }
    return nameValueIndex;
}

#pragma mark Creation methods.

+ (SpdyStream *)newFromCFHTTPMessage:(CFHTTPMessageRef)msg delegate:(SpdyCallback *)delegate body:(NSInputStream *)body {
    SpdyStream *stream = [[SpdyStream alloc] init];
    CFURLRef u = CFHTTPMessageCopyRequestURL(msg);
    stream.url = (__bridge NSURL *)u;
    if (body != nil) {
        stream.body = body;
    } else {
        CFDataRef bodyData = CFHTTPMessageCopyBody(msg);
        if (bodyData != NULL) {
            stream.body = [NSInputStream inputStreamWithData:(__bridge NSData *)bodyData];
            CFRelease(bodyData);
        }
    }
    stream.delegate = delegate;
    stream.stringArena = [stream createArena:1024];
    [stream serializeHeaders:msg];
    CFRelease(u);
    return stream;
}

+ (SpdyStream *)newFromNSURL:(NSURL *)url delegate:(SpdyCallback *)delegate {
    SpdyStream *stream = [[SpdyStream alloc] init];
    stream.nameValues = malloc(sizeof(const char *) * (6*2 + 1));
    stream.delegate = delegate;
    stream.stringArena = [stream createArena:512];
    NSInteger next = [stream serializeUrl:url withMethod:@"GET" withVersion:@"HTTP/1.1"];
    assert(next == 10);
    stream.nameValues[10] = "user-agent";
    stream.nameValues[11] = "SPDY obj-c/0.7.5";
    stream.nameValues[12] = NULL;
    return stream;
}

+ (SpdyStream *)newFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate {
    SpdyStream *stream = [[SpdyStream alloc] init];
    NSDictionary *headers = [request allHTTPHeaderFields];
    stream.delegate = delegate;
    stream.stringArena = [stream createArena:2048];
    unsigned long maxElements = [headers count]*2 + 6*2 + 1;
    stream.nameValues = malloc(sizeof(const char *) * maxElements);
    int nameValueIndex = [stream serializeUrl:[request URL] withMethod:[request HTTPMethod] withVersion:@"HTTP/1.1"];
    nameValueIndex = [stream serializeHeadersDict:headers fromIndex:nameValueIndex];
    stream.nameValues[nameValueIndex] = NULL;
    stream.body = request.HTTPBodyStream;
    if (request.HTTPBodyStream == nil && request.HTTPBody != nil)
        stream.body = [NSInputStream inputStreamWithData:request.HTTPBody];

    if (stream.streamTimeoutInterval == 0.0)
        stream.streamTimeoutInterval = [request timeoutInterval];
    else
        stream.streamTimeoutInterval = MIN([request timeoutInterval], stream.streamTimeoutInterval);
    return stream;
}

+ (SpdyStream *)newFromAssociatedStream:(SpdyStream *)associatedStream streamId:(int32_t)streamId nameValues:(char**)nv {
  SpdyStream *stream = [[SpdyStream alloc] init];

  if([associatedStream.delegate isKindOfClass:[SpdyBufferedCallback class]]) {
    stream.delegate = [[SpdyPushCallback alloc] initWithParentCallback:(SpdyBufferedCallback*)associatedStream.delegate andStreamId:streamId];
  } else {
    SPDY_LOG(@"ignoring push stream because the delegate of the associated stream is not a SpdyBufferedCallback (it is %@)", [stream.delegate class]);
  }

  stream.streamId = streamId;
  stream.stringArena = [stream createArena:2048]; // XXX ??? not sure about this

  int maxElements = 0;
  while(nv[2*maxElements] != NULL) maxElements++;
  
  stream.nameValues = malloc(sizeof(const char *) * maxElements * 2 + 1);
  for(int i = 0 ; i < maxElements*2 ; i++) 
    stream.nameValues[i] = nv[i];

  return stream;
}
@end
