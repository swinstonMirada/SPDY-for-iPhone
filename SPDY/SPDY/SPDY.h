//
//  SPDY.h
//  SPDY library
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

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

@class SpdySession;

typedef enum {
  kSpdyNotConnected,
  kSpdyConnecting,
  kSpdySslHandshake,
  kSpdyConnected,
  kSpdyGoAwaySubmitted,
  kSpdyGoAwayReceived,
  kSpdyError,
} SpdyConnectState;

#define kSpdyStreamNotFound -1
#define kSpdyHostNotFound -2

typedef enum {
    kSpdyNotReachable = 0,
    kSpdyReachableViaWWAN,
    kSpdyReachableViaWiFi	
} SpdyNetworkStatus;

@class SpdyCallback;
@class SpdyHTTPResponse;

typedef void (^SpdySuccessCallback)(SpdyHTTPResponse*,NSData*);
typedef void (^SpdyErrorCallback)(NSError*);
typedef void (^SpdyVoidCallback)();
typedef void (^SpdyIntCallback)(int);
typedef void (^SpdyTimeIntervalCallback)(NSTimeInterval);

// Returns a CFReadStream.  If requestBody is non-NULL the request method in requestHeaders must
// support a message body and the requestBody will override the body that may already be in requestHeaders.  If
// the request method in requestHeaders expects a body and requestBody is NULL then the body from requestHeaders
// will be used.
CFReadStreamRef SpdyCreateSpdyReadStream(CFAllocatorRef alloc, CFHTTPMessageRef requestHeaders, CFReadStreamRef requestBody);

extern NSString *kSpdyErrorDomain;
extern NSString *kOpenSSLErrorDomain;
extern NSString *kSpdyTimeoutHeader;


enum SpdyErrors {
    kSpdyConnectionOk = 0,
    kSpdyConnectionFailed = 1,
    kSpdyRequestCancelled = 2,
    kSpdyConnectionNotSpdy = 3,
    kSpdyInvalidResponseHeaders = 4,
    kSpdyHttpSchemeNotSupported = 5,
    kSpdyStreamClosedWithNoRepsonseHeaders = 6,
    kSpdyVoipRequestedButFailed = 7,
    kSpdyConnectTimeout = 9,
};

@protocol SpdyRequestIdentifier <NSObject>
- (NSURL *)url;
- (void)close;
@end

@protocol SpdyUrlConnectionCallback <NSObject>

- (BOOL)shouldUseSpdyForUrl:(NSURL *)url;

@end

#ifdef CONF_Debug
// The SpdyLogger protocol is used to log from the spdy library.  The default SpdyLogger prints out ugly logs with NSLog.  You'll probably
// want to override the default.
@protocol SpdyLogger
- (void)writeSpdyLog:(NSString *)message file:(const char *)file line:(int)line;
@end
#endif

@interface SPDY : NSObject

+ (SPDY *)sharedSPDY;

@property (nonatomic,copy) SpdyVoidCallback needToStartBackgroundTaskBlock;
@property (nonatomic,copy) SpdyVoidCallback finishedWithBackgroundTaskBlock;

// Call registerForNSURLConnection to enable spdy when using NSURLConnection.  SPDY responses can be identified (in iOS 5.0+) by looking for
// the @"protocol-was: spdy" header with the value @"YES".  "protocol-was: spdy" is not a valid http header, thus it is safe to add it.
// WARNING: Using NSURLConnection means that upload progress can not be monitored.  This is because of a lack of an API in URLProtocolClient.
- (void)registerForNSURLConnection;

// Like registerForNSURLConnection but callback is called for each request.  Callback is retained.
- (void)registerForNSURLConnectionWithCallback:(id <SpdyUrlConnectionCallback>)callback;
- (BOOL)isSpdyRegistered;
- (BOOL)isSpdyRegisteredForUrl:(NSURL *)url;
- (void)unregisterForNSURLConnection;

- (int)pingWithCallback:(void (^)())callback;
- (void)pingUrlString:(NSString*)url callback:(void (^)())callback;
- (void)pingRequest:(NSURLRequest*)request callback:(void (^)())callback;
- (void)teardown:(NSString*)url;
- (void)teardownForRequest:(NSURLRequest*)url;

+ (SpdyNetworkStatus)networkStatusForReachabilityFlags:(SCNetworkReachabilityFlags)flags;
- (SpdyNetworkStatus)networkStatusForUrlString:(NSString*)url;
- (SpdyNetworkStatus)networkStatusForRequest:(NSURLRequest*)request;
- (SpdyConnectState)connectStateForUrlString:(NSString*)url;
- (SpdyConnectState)connectStateForRequest:(NSURLRequest*)request;

// A reference to delegate is kept until the stream is closed.  The caller will get an onError or onStreamClose before the stream is closed.
- (SpdySession*)fetch:(NSString *)path delegate:(SpdyCallback *)delegate;
- (SpdySession*)fetch:(NSString *)path delegate:(SpdyCallback *)delegate voip:(BOOL)voip;
- (SpdySession*)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate;
- (SpdySession*)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate;
- (SpdySession*)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate voip:(BOOL)voip;

// Cancels all active requests and closes all connections.  Returns the number of requests that were cancelled.  Ideally this should be called when all requests have already been canceled.
- (NSInteger)closeAllSessions;

#ifdef CONF_Debug
@property (strong) NSObject<SpdyLogger> *logger;
#endif

// Like closeAllSessions above, but only cancels and closes for url.host:url.port.
- (NSInteger)closeAllSessionsForURL:(NSURL *)url;

@end




#ifdef CONF_Debug

/* logging only on the Debug configuration */

#define SPDY_LOG(fmt, ...) do { \
    NSString * msg = [[NSString alloc] initWithFormat:fmt, ##__VA_ARGS__]; \
    [[SPDY sharedSPDY].logger writeSpdyLog:msg file:__FILE__ line:__LINE__]; \
    if (0) NSLog(fmt, ## __VA_ARGS__);					\
} while (0);

#define SPDY_DEBUG_LOG(fmt, ...) do { \
    NSString * msg = [[NSString alloc] initWithFormat:fmt, ##__VA_ARGS__]; \
    [[SPDY sharedSPDY].logger writeSpdyLog:msg file:__FILE__ line:__LINE__];\
    if (0) NSLog(fmt, ## __VA_ARGS__); \
} while (0);

#else

/* no logging at all on release builds */

#define SPDY_LOG(fmt, ...) { }
#define SPDY_DEBUG_LOG(fmt, ...) { }

#endif
