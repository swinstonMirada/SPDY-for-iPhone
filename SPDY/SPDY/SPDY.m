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
#import "SpdyCallback.h"

// The shared spdy instance.
static SPDY *spdy = NULL;
NSString *kSpdyErrorDomain = @"SpdyErrorDomain";
NSString *kOpenSSLErrorDomain = @"OpenSSLErrorDomain";

static int select_next_proto_cb(SSL *ssl,
                                unsigned char **out, unsigned char *outlen,
                                const unsigned char *in, unsigned int inlen,
                                void *arg) {
  SpdySession *sc = (__bridge SpdySession *)SSL_get_app_data(ssl);
  int spdyVersion = spdylay_select_next_protocol(out, outlen, in, inlen);
  if (spdyVersion > 0) {
    sc.spdyVersion = spdyVersion;
    sc.spdyNegotiated = YES;
  }
    
  return SSL_TLSEXT_ERR_OK;
}

#ifdef CONF_Debug
@interface SpdyLogImpl : NSObject<SpdyLogger>
@end

@implementation SpdyLogImpl


- (void)writeSpdyLog:(NSString *)msg file:(const char *)file line:(int)line {
  NSLog(@"[%s:%d]", file, line);
  NSLog(@"%@", msg);
}
@end
#endif

@interface SPDY ()
- (SpdySession*)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate body:(NSInputStream *)body;
+ (SpdyNetworkStatus)reachabilityStatusForHost:(NSString *)host;

- (void)setUpSslCtx;

@property (nonatomic, strong) NSMutableDictionary *sessions;
@property (nonatomic, assign) SSL_CTX *ssl_ctx;

@end

@implementation SPDY

#ifdef CONF_Debug
@synthesize logger = _logger;
#endif
@synthesize sessions = _sessions;
@synthesize ssl_ctx =  _ssl_ctx;

// This logic was stripped from Apple's Reachability.m sample application.
+ (SpdyNetworkStatus)networkStatusForReachabilityFlags:(SCNetworkReachabilityFlags)flags {
  // Host not reachable.
  if ((flags & kSCNetworkReachabilityFlagsReachable) == 0)
    return kSpdyNetworkStatusNotReachable;
    
  // Host reachable by WWAN.
  if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN)
    return kSpdyNetworkStatusReachableViaWWAN;
    
  // Host reachable and no connection is required. Assume wifi.
  if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0)
    return kSpdyNetworkStatusReachableViaWiFi;
    
  // Host reachable. Connection is on-demand or on-traffic. No user intervention needed. Assume wifi.
  if (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand) != 0) ||
      ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)) {
    if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0)
      return kSpdyNetworkStatusReachableViaWiFi;
  }
    
  return kSpdyNetworkStatusNotReachable;
}

+ (SpdyNetworkStatus)reachabilityStatusForHost:(NSString *)host {	
  SpdyNetworkStatus status = kSpdyNetworkStatusNotReachable;
  SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithName(NULL, [host UTF8String]);
  if (ref) {
    SCNetworkReachabilityFlags flags = 0;
    if (SCNetworkReachabilityGetFlags(ref, &flags))
      status = [self networkStatusForReachabilityFlags:flags];
        
    CFRelease(ref);
  }
  return status;
}

-(SSL_SESSION *)resetSession:(SpdySession*)session  withKey:(SpdySessionKey*)key {
  [session resetStreamsAndGoAway];
  SSL_SESSION * oldSslSession = [session getSslSession];
  SPDY_LOG(@"removing session object (%p) for key %@", self, key);
  [self.sessions removeObjectForKey:key];
  SPDY_LOG(@"after remove we have %lu sessions", (unsigned long)self.sessions.count);
  return oldSslSession;
}

-(SSL_SESSION *)resetSession:(SpdySession*)session  withUrl:(NSURL*)key {
  return [self resetSession:session 
	       withKey:[[SpdySessionKey alloc] 
			 initFromUrl:key]];
}

- (SpdySession *)getSession:(NSURL *)url withError:(NSError **)error voip:(BOOL)voip create:(BOOL)create {

  assert(error != NULL);
  SpdySessionKey *key = [[SpdySessionKey alloc] initFromUrl:url];
  SpdySession *session = [self.sessions objectForKey:key];
  SPDY_LOG(@"Looking up %@, found %p", key, session);
  SpdyNetworkStatus currentStatus = [self.class reachabilityStatusForHost:key.host];
  SSL_SESSION *oldSslSession =  NULL;
  SpdySession *oldSpdySession = nil;
  if (session != nil && ([session isInvalid] || 
			 (currentStatus != session.networkStatus &&
			  !(session.networkStatus == kSpdyNetworkStatusReachableViaWWAN && 
			    currentStatus == kSpdyNetworkStatusReachableViaWiFi)))) {
    SPDY_LOG(@"Resetting %@ because invalid: %i or %@ != %@", session, [session isInvalid], [SPDY networkStatusString:currentStatus], [SPDY networkStatusString:session.networkStatus]);
    oldSslSession = [self resetSession:session withKey:key];
    oldSpdySession = session;
    session = nil;
  }
  if (create && session == nil) {
    session = [[SpdySession alloc] init:self.ssl_ctx oldSession:oldSslSession];
    SPDY_LOG(@"creating new session %p w/ old session %@", session, oldSpdySession);
    session.voip = voip;

    SPDY_LOG(@"callbacks are %@ %@ %@", oldSpdySession.readCallback, 
	     oldSpdySession.writeCallback, oldSpdySession.connectionStateCallback);

    session.readCallback = oldSpdySession.readCallback;
    session.writeCallback = oldSpdySession.writeCallback;
    session.connectionStateCallback = oldSpdySession.connectionStateCallback;
    *error = [session connect:url];
    if (*error != nil) {
      SPDY_LOG(@"Could not connect to %@ because %@", url, *error);
      return nil;
    }
    SPDY_LOG(@"Adding %@ to sessions (size = %lu)", key, (unsigned long)([self.sessions count] + 1));
    currentStatus = [self.class reachabilityStatusForHost:key.host];
    session.networkStatus = currentStatus;
    [self.sessions setObject:session forKey:key];
    SPDY_LOG(@"self.sessions has %lu elements", (unsigned long)self.sessions.count);
  } else {
    SPDY_LOG(@"not creating new session, returing %@", session);
  }
  return session;
}

- (int)pingWithCallback:(void (^)())callback {
  int ret = 0;
  SPDY_LOG(@"pingWithCallback w/ %lu sessions", (unsigned long)self.sessions.count);
  for(SpdySessionKey *sessionKey in self.sessions) {
    SpdySession *session = [self.sessions objectForKey:sessionKey];
    if (session != nil) {
      ret++;
      SPDY_LOG(@"pinging session %@", session);
      [session sendPingWithCallback:callback];
    }
  }
  return ret;
}

- (void)pingRequest:(NSURLRequest*)request callback:(void (^)())callback {
  NSURL *url = [request URL];
  NSError *error;
  SpdySession *session = [self getSession:(NSURL *)url withError:&error voip:NO create:YES];
  if (session == nil) {
    // XXX log error
    SPDY_LOG(@"could not ping: no session");
    return;
  }
  [session sendPingWithCallback:callback];
}

- (void)pingUrlString:(NSString*)url callback:(void (^)())callback {
  NSURL *u = [NSURL URLWithString:url];
  if (u == nil || u.host == nil) {
    //NSError *error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
    // XXX log error
    SPDY_LOG(@"could not ping: bad host");
    return;
  }
  NSError *error = nil;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:YES];
  if (session == nil) {
    // XXX log error
    SPDY_LOG(@"could not ping: no session");
    return;
  }
  [session sendPingWithCallback:callback];
}

-(SpdySession*)fetch_internal:(NSString*)url delegate:(SpdyCallback *)delegate voip:(BOOL)voip {
  SPDY_LOG(@"fetch_internal");
  NSURL *u = [NSURL URLWithString:url];
  if (u == nil || u.host == nil) {
    NSError *error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
    [delegate onError:error];
    return nil;
  }
  NSError *error = nil;
  SpdySession *session = [self getSession:u withError:&error voip:voip create:YES];
  if (session == nil) {
    [delegate onError:error];
    return nil;
  }
  session.voip = voip;
  SPDY_LOG(@"calling fetch on session %@", session); 
  [session fetch:u delegate:delegate];
  return session;
}

- (void)teardownForRequest:(NSURLRequest*)request {
  NSURL *url = [request URL];
  NSError *error;
  SpdySession *session = [self getSession:url withError:&error voip:NO create:NO];
  if (session == nil) {
    SPDY_LOG(@"Warning, session == nil in teardownForRequest:%@", request);
   return;
  }
  [self resetSession:session withUrl:url];
}

- (void)teardown:(NSString*)url {
  NSURL *u = [NSURL URLWithString:url];
  if (u == nil || u.host == nil) {
    return;
  }
  NSError *error = nil;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:NO];
  if (session == nil) {
    SPDY_LOG(@"Warning, session == nil in teardown:%@", url);
    return;
  }
  SPDY_LOG(@"tearing down spdy session %p", session);
  [self resetSession:session withUrl:u];
}

- (SpdyConnectState)connectStateForUrlString:(NSString*)url {
  NSURL *u = [NSURL URLWithString:url];
  if (u == nil || u.host == nil) {
    return kSpdyConnectStateHostNotFound;
  }
  NSError *error = nil;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:NO];
  if (session == nil) {
    return kSpdyConnectStateStreamNotFound;
  }
  return session.connectState;
}

- (SpdyConnectState)connectStateForRequest:(NSURLRequest*)request {
  NSURL * u = request.URL;
  NSError *error;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:NO];
  if (session == nil) {
    return kSpdyConnectStateStreamNotFound;
  }
  return session.connectState;
}

- (SpdyNetworkStatus)networkStatusForUrlString:(NSString*)url {
  NSURL *u = [NSURL URLWithString:url];
  if (u == nil || u.host == nil) {
    return kSpdyNetworkStatusHostNotFound;
  }
  NSError *error = nil;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:NO];
  if (session == nil) {
    return kSpdyNetworkStatusStreamNotFound;
  }
  return session.networkStatus;
}

- (SpdyNetworkStatus)networkStatusForRequest:(NSURLRequest*)request {
  NSURL *u = request.URL;
  if (u == nil || u.host == nil) {
    return kSpdyNetworkStatusHostNotFound;
  }
  NSError *error;
  SpdySession *session = [self getSession:u withError:&error voip:NO create:NO];
  if (session == nil) {
    return kSpdyNetworkStatusStreamNotFound;
  }
  return session.networkStatus;
}

- (SpdySession*)fetch:(NSString *)url delegate:(SpdyCallback *)delegate {
  SPDY_LOG(@"fetch:");
  return [self fetch_internal:url delegate:delegate voip:NO];
}

- (SpdySession*)fetch:(NSString *)url delegate:(SpdyCallback *)delegate voip:(BOOL)voip {
  SPDY_LOG(@"fetch:");
  return [self fetch_internal:url delegate:delegate voip:voip];
}

- (SpdySession*)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate {
  SPDY_LOG(@"fetch:");
  return [self fetchFromMessage:request delegate:delegate body:nil];
}

- (SpdySession*)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate body:(NSInputStream *)body {
  SPDY_LOG(@"fetch:");
    CFURLRef url = CFHTTPMessageCopyRequestURL(request);
    NSError *error;
    SpdySession *session = [self getSession:(__bridge NSURL *)url withError:&error voip:NO create:YES];
    if (session == nil) {
        [delegate onError:error];
    } else {
        [session fetchFromMessage:request delegate:delegate body:body];
    }
    CFRelease(url);    
    return session;
}

- (SpdySession*)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate {
  SPDY_LOG(@"fetch:");
  return [self fetchFromRequest:request delegate:delegate voip:NO];
}

- (SpdySession*)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate voip:(BOOL)voip {
  SPDY_LOG(@"fetch:");
  NSURL *url = [request URL];
  NSError *error;
  SpdySession *session = [self getSession:(NSURL *)url withError:&error voip:voip create:YES];
  if (session == nil) {
    [delegate onError:error];
  } else {
    [session fetchFromRequest:request delegate:delegate];
  }
  return session;
}

- (NSInteger)closeAllSessions {
  SPDY_LOG(@"closeAllSessions");
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
    SpdySessionKey *urlKey = [[SpdySessionKey alloc] initFromUrl:url];
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
#ifdef CONF_Debug
    if(self.logger == nil)
      self.logger = [[SpdyLogImpl alloc] init];
#endif
    self.sessions = [[NSMutableDictionary alloc] init];
    [self setUpSslCtx];
  }
  return self;
}

- (void)dealloc {
    SSL_CTX_free(_ssl_ctx);
}

- (void)setUpSslCtx {
    self.ssl_ctx = SSL_CTX_new(SSLv23_client_method());
    assert(self.ssl_ctx);
    
    /* Disable SSLv2 and enable all workarounds for buggy servers */
    SSL_CTX_set_options(self.ssl_ctx, SSL_OP_ALL|SSL_OP_NO_SSLv2);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_AUTO_RETRY);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_mode(self.ssl_ctx, SSL_MODE_ENABLE_PARTIAL_WRITE);
    SSL_CTX_set_next_proto_select_cb(self.ssl_ctx, select_next_proto_cb, (__bridge void *)(self));
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


+(NSString*)connectionStateString:(SpdyConnectState) state {
  switch(state) {
  case kSpdyConnectStateNotConnected:
    return @"NotConnected";
  case kSpdyConnectStateConnecting:
    return @"Connecting";
  case kSpdyConnectStateSslHandshake:
    return @"SslHandshake";
  case kSpdyConnectStateConnected:
    return @"Connected";
  case kSpdyConnectStateError:
    return @"Error";
  case kSpdyConnectStateGoAwaySubmitted:
    return @"Sent GoAway";
  case kSpdyConnectStateGoAwayReceived:
    return @"Got GoAway";
  case kSpdyConnectStateHostNotFound:
    return @"NO HOST";
  case kSpdyConnectStateStreamNotFound:
    return @"NO STREAM";
  }


  return @"Unknown";

}

+(NSString*)radioAccessString:(SpdyRadioAccessTechnology)status {
  switch(status) {
  case SpdyRadioAccessTechnologyNone:
    return @"None";
    break;
  case SpdyRadioAccessTechnologyGPRS:
    return @"GPRS";
    break;
  case SpdyRadioAccessTechnologyEdge:
    return @"Edge";
    break;
  case SpdyRadioAccessTechnologyWCDMA:
    return @"WCDMA";
    break;
  case SpdyRadioAccessTechnologyHSDPA:
    return @"HSDPA";
    break;
  case SpdyRadioAccessTechnologyHSUPA:
    return @"HSUPA";
    break;
  case SpdyRadioAccessTechnologyCDMA1x:
    return @"CDMA1x";
    break;
  case SpdyRadioAccessTechnologyCDMAEVDORev0:
    return @"CDMAEVDORev0";
    break;
  case SpdyRadioAccessTechnologyCDMAEVDORevA:
    return @"CDMAEVDORevA";
    break;
  case SpdyRadioAccessTechnologyCDMAEVDORevB:
    return @"CDMAEVDORevB";
    break;
  case SpdyRadioAccessTechnologyeHRPD:
    return @"eHRPD";
    break;
  case SpdyRadioAccessTechnologyLTE:
    return @"LTE";
    break;
  default:
  case SpdyRadioAccessTechnologyUnknown:
    return @"Unknown";
    break;
  }
}

+(NSString*)networkStatusString:(SpdyNetworkStatus)status {
  switch(status) {
  case kSpdyNetworkStatusNotReachable:
    return @"Not";
  case kSpdyNetworkStatusReachableViaWWAN:
    return @"WWAN";
  case kSpdyNetworkStatusReachableViaWiFi:  
    return @"WIFI";
  case kSpdyNetworkStatusHostNotFound:
    return @"NO HOST";
  case kSpdyNetworkStatusStreamNotFound:
    return @"NO STREAM";
  }

  return @"Unknown";
}

@end




// Create a delegate derived class of SpdyCallback.  Create a context struct.
// Convert this to an objective-C object that derives from SpdyCallback.
@interface _SpdyCFStream : SpdyCallback {
    CFWriteStreamRef writeStreamPair;  // read() will write into writeStreamPair.
    unsigned long long requestBytesWritten;
};

@property (assign) BOOL opened;
@property (assign) int error;
@property (strong) SpdyInputStream *readStreamPair;

@end


@implementation _SpdyCFStream

@synthesize opened;
@synthesize error;
@synthesize readStreamPair;

- (_SpdyCFStream *)init:(CFAllocatorRef)a {
    self = [super init];
    
    CFReadStreamRef baseReadStream;
    CFStreamCreateBoundPair(a, &baseReadStream, &writeStreamPair, 16 * 1024);
    self.readStreamPair = [[SpdyInputStream alloc] init:(__bridge NSInputStream *)baseReadStream];
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
    _SpdyCFStream *ctx = [[_SpdyCFStream alloc] init:alloc];
    if (ctx) {
        SPDY *spdy = [SPDY sharedSPDY];
        [spdy fetchFromMessage:requestHeaders delegate:ctx body:(__bridge NSInputStream *)requestBody];
        return (CFReadStreamRef)CFBridgingRetain([ctx readStreamPair]);
     }
     return NULL;
}
                         

