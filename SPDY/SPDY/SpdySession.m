//
//  SpdySession.m
//  This class is the only one that deals with both SSL and spdylay.
//  To replace the base spdy library, this is the only class that should
//  be change.
//
//  Created by Jim Morrison on 2/8/12.
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

#import "SpdySession.h"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netdb.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>


#import "SPDY.h"
#import "SpdyStream.h"
#import "SpdyCallback.h"
#import "SpdyRequest+Private.h"
#include "openssl/ssl.h"
#include "openssl/err.h"
#include "spdylay/spdylay.h"

#define STREAM_KEY(streamId) [NSString stringWithFormat:@"%ld", (long)streamId]

static const int priority = 1;

@interface SpdySession ()

#define SSL_HANDSHAKE_SUCCESS 0
#define SSL_HANDSHAKE_NEED_TO_RETRY 1

#define HTTPS_SCHEME @"https"
#define HTTPS_PORT "443"

@property (retain, nonatomic) NSDate *lastCallbackTime;

- (void)_cancelStream:(SpdyStream *)stream;
- (NSError *)connectTo:(NSURL *)url;
- (void)connectionFailed:(NSInteger)error domain:(NSString *)domain;
- (void)invalidateSocket;
- (void)removeStream:(SpdyStream *)stream;
- (int)send_data:(const uint8_t *)data len:(size_t)len flags:(int)flags;
- (BOOL)sslConnect;
- (int)sslHandshake;  // Returns SSL_HANDSHAKE_SUCCESS if the handshake completed.
- (void)sslError;
- (BOOL)submitRequest:(SpdyStream *)stream;
- (BOOL)wouldBlock:(int)r;
- (ssize_t)fixUpCallbackValue:(int)r;

@property (nonatomic, assign) CFReadStreamRef readStream;
@property (nonatomic, assign) CFWriteStreamRef writeStream;
@end


@implementation SpdySession {
  struct spdylay_session *session;
    
  BOOL spdyNegotiated;
  SpdyConnectState connectState;
  SpdyNetworkStatus networkStatus;
  void (^pingCallback)();

  NSMutableSet *streams;
  NSMutableDictionary *pushStreams;
    
  CFSocketRef socket;

  SSL *ssl;
  SSL_CTX *ssl_ctx;
  SSL_SESSION *oldSslSession;
  spdylay_session_callbacks *callbacks;

  SpdyTimer * connectionTimer;

  dispatch_source_t read_source;
  dispatch_source_t write_source;

  BOOL write_source_enabled;
}

-(id)init {
  self = [super init];
  if(self) {
    read_source = NULL;
    write_source = NULL;
  }
  return self;
}

@synthesize spdyNegotiated;
@synthesize spdyVersion;
@synthesize session;
@synthesize host;
@synthesize voip;
@synthesize networkStatus;

-(SpdyConnectState)connectState {
  return connectState;
}

-(void)setConnectState:(SpdyConnectState)state {
  connectState = state;
  SPDY_LOG(@"%p self.connectionStateCallback is %@", self, self.connectionStateCallback);
  if(self.connectionStateCallback != NULL)
    self.connectionStateCallback(state);
}

- (SpdyStream*)pushStreamForId:(int32_t)stream_id {
  return [pushStreams objectForKey:STREAM_KEY(stream_id)];
}

- (void)invalidateSocket {
  if (socket == nil)
    return;

  SPDY_LOG(@"%p invalidateSocket", self);

  self.connectState = kSpdyConnectStateNotConnected;

  CFSocketInvalidate(socket);
  CFRelease(socket);
  [self releaseStreams];
  [self releaseDispatchSources];
  socket = nil;
}

- (void)sslError {
  SPDY_LOG(@"%p %s", self, ERR_error_string(ERR_get_error(), 0));
  [self invalidateSocket];
}

static int make_non_block(int fd) {
  int flags, r;
  while ((flags = fcntl(fd, F_GETFL, 0)) == -1 && errno == EINTR);
  if (flags == -1)
    return -1;
  while ((r = fcntl(fd, F_SETFL, flags | O_NONBLOCK)) == -1 && errno == EINTR);
  if (r == -1)
    return -1;
  return 0;
}

static SpdyStream * get_stream_for_id(spdylay_session *session, int32_t stream_id, void* user_data) {
  SpdyStream *spdyStream = (__bridge SpdyStream *)(spdylay_session_get_stream_user_data(session, stream_id));
  if(spdyStream == nil) {
    SpdySession * spdySession = (__bridge SpdySession*)user_data;
    spdyStream = [spdySession pushStreamForId:stream_id];
  }
  return spdyStream;
}

static ssize_t read_from_data_callback(spdylay_session *session, int32_t stream_id, uint8_t *buf, size_t length, int *eof, spdylay_data_source *source, void *user_data) {
  NSInputStream* stream = (__bridge NSInputStream*)source->ptr;
  NSInteger bytesRead = [stream read:buf maxLength:length];
  if (![stream hasBytesAvailable]) {
    *eof = 1;
    [stream close];
  }
  SpdyStream *spdyStream = get_stream_for_id(session, stream_id, user_data);
  if(spdyStream != nil) {
    if (bytesRead > 0) {
      [[spdyStream delegate] onRequestBytesSent:bytesRead];
    }
  } else {
    SPDY_LOG(@"%p unhandled stream in read_from_data_callback", spdyStream);
  }
  return bytesRead;
}

- (NSError *)connectTo:(NSURL *)url {
    
  char service[10];
  NSNumber *port = [url port];
  if (port != nil) {
    snprintf(service, sizeof(service), "%u", [port intValue]);
  } else {
    NSString * scheme = [url scheme];
    //SPDY_LOG(@"%p got scheme %@", self, scheme);
    if([scheme isEqualToString:HTTPS_SCHEME ]) {
      snprintf(service, sizeof(service), HTTPS_PORT);
      /* 
	 in theory, bare http could be supported.
	 in practice, we require tls / ssl / https.
      */	 
    } else {
      self.connectState = kSpdyConnectStateError;
      NSDictionary * dict = [NSDictionary 
			      dictionaryWithObjectsAndKeys:
				[[NSString alloc] 
				  initWithFormat:@"Scheme %@ not supported", scheme], 
			      @"reason", nil];
      return [NSError errorWithDomain:kSpdyErrorDomain 
		      code:kSpdyHttpSchemeNotSupported 
		      userInfo:dict];
    }
  }
    
  struct addrinfo hints;
  memset(&hints, 0, sizeof(struct addrinfo));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
    
  struct addrinfo *res;
  SPDY_LOG(@"%p Looking up hostname for %@", self, [url host]);
  int err = getaddrinfo([[url host] UTF8String], service, &hints, &res);
  if (err != 0) {
    NSError *error;
    if (err == EAI_SYSTEM) {
      error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    } else {
      error = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:err userInfo:nil];
    }
    SPDY_LOG(@"%p Error getting IP address for %@ (%@)", self, url, error);
    self.connectState = kSpdyConnectStateError;
    return error;
  }

  struct addrinfo* rp = res;
  if (rp != NULL) {
    CFSocketContext ctx = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFDataRef address = CFDataCreate(NULL, (const uint8_t*)rp->ai_addr, rp->ai_addrlen);
    socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, NULL, &ctx);

    int sock = CFSocketGetNative(socket);

    read_source = 
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 
			     0, __spdy_dispatch_queue());

    write_source = 
      dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, sock, 
			     0, __spdy_dispatch_queue());

    dispatch_source_set_event_handler(read_source, ^{ [self sessionRead]; });
    dispatch_source_set_event_handler(write_source, ^{ [self sessionWrite]; });

    dispatch_block_t write_cancel_handler = ^{ 
      close(sock); 
    };

    dispatch_block_t read_cancel_handler = ^{ 
      close(sock); 
    };

    dispatch_source_set_cancel_handler(write_source, write_cancel_handler);
    dispatch_source_set_cancel_handler(read_source, read_cancel_handler);

    dispatch_resume(write_source);
    write_source_enabled = YES;
    dispatch_resume(read_source);

    CFSocketConnectToAddress(socket, address, -1);
        
    // Ignore write failures, and deal with then on write.
    int set = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));

    CFRelease(address);
    self.connectState = kSpdyConnectStateConnecting;
    freeaddrinfo(res);

    SPDY_LOG(@"%p starting connectionTimer", self);
    [connectionTimer invalidate];
    connectionTimer = [[SpdyTimer alloc] initWithInterval:12 // XXX hardcoded
					 andBlock:^{ [self connectionTimedOut]; }];
    [connectionTimer start];
    return nil;
  }
  self.connectState = kSpdyConnectStateError;
  return [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
}

- (void)notSpdyError {
  self.connectState = kSpdyConnectStateError;
    
  @synchronized(streams) {
    for (SpdyStream *stream in streams) {
      [stream notSpdyError];
    }
  }
}

-(void)connectionTimedOut {
  SPDY_LOG(@"%p connectionTimer connectionTimedOut", self);
  [connectionTimer invalidate];	// just in case
  connectionTimer = nil;
  [self connectionFailed:kSpdyConnectTimeout domain:kSpdyErrorDomain]; 
}

- (void)connectionFailed:(NSInteger)err domain:(NSString *)domain {
  SPDY_LOG(@"%p connectionFailed:%ld domain:%@", self, (long)err, domain);

  if([SPDY sharedSPDY].needToStartBackgroundTaskBlock != NULL) 
    [SPDY sharedSPDY].needToStartBackgroundTaskBlock();

  SPDY_LOG(@"%p invalidating connectionTimer", self);
  [connectionTimer invalidate];
  connectionTimer = nil;
  self.connectState = kSpdyConnectStateError;
  [self invalidateSocket];
  NSError *error = [NSError errorWithDomain:domain code:err userInfo:nil];
  SPDY_LOG(@"%p we have %lu streams", self, (unsigned long)streams.count);
  @synchronized(streams) {
    for (SpdyStream *value in streams) {
      SPDY_LOG(@"%p sending error to delegate %@", self, value.delegate);
      [value.delegate onError:error];
    }
  }
  
  if([SPDY sharedSPDY].finishedWithBackgroundTaskBlock != NULL) 
    [SPDY sharedSPDY].finishedWithBackgroundTaskBlock();
}

- (void)_cancelStream:(SpdyStream *)stream {
  [stream cancelStream];
  if (stream.streamId > 0) {
    spdylay_submit_rst_stream([self session], (int32_t)stream.streamId, SPDYLAY_CANCEL);
  }
}

- (void)cancelStream:(SpdyStream *)stream {
  // Do not remove the stream here as it will be removed on the close callback when spdylay is done with the object.
  [self _cancelStream:stream];
  if ([[NSDate date] compare:[self.lastCallbackTime dateByAddingTimeInterval:stream.streamTimeoutInterval]] == NSOrderedDescending)
    SPDY_LOG(@"%p Stream %@ timed out, timeout set at %fs", self, stream, stream.streamTimeoutInterval);
}

- (NSInteger)resetStreamsAndGoAway {
  SPDY_LOG(@"%p resetStreamsAndGoAway", self);
  @synchronized(streams) {
    NSInteger cancelledStreams = [streams count];
    for (SpdyStream *stream in streams) {
      [self _cancelStream:stream];
    }
    self.connectState = kSpdyConnectStateGoAwaySubmitted;
    if (session != nil) {
      SPDY_LOG(@"%p submitting goaway", self);
      spdylay_submit_goaway(session, SPDYLAY_GOAWAY_OK);
      spdylay_session_send(session);
    }
    return cancelledStreams;
  }
}

- (SSL_SESSION *)getSslSession {
  if (ssl)
    return SSL_get1_session(ssl);
  return NULL;
}

- (BOOL)isInvalid {
  return socket == nil;
}

- (BOOL)submitRequest:(SpdyStream *)stream {
  
  SPDY_LOG(@"%p submit request", self);
  if (!self.spdyNegotiated) {
    [stream notSpdyError];
    return NO;
  }

  spdylay_data_provider data_prd = {-1, NULL};
  if (stream.body != nil) {
    [stream.body open];
    data_prd.source.ptr = (__bridge void *)(stream.body);
    data_prd.read_callback = read_from_data_callback;
  }
  if (spdylay_submit_request(session, priority, [stream nameValues], &data_prd, (__bridge void *)(stream)) < 0) {
    SPDY_LOG(@"%p Failed to submit request for %@", self, stream);
    [stream connectionError];
    return NO;
  }
  return YES;
}

- (int)sslHandshake {
  //SPDY_LOG(@"trying to ssl handshake");
  int r = SSL_connect(ssl);
  //SPDY_LOG(@"SSL_connect returned %d", r);
  if (r == 1) {
    // The TLS/SSL handshake was successfully completed, 
    // a TLS/SSL connection has been established.
    SPDY_LOG(@"%p connected", self);
    self.connectState = kSpdyConnectStateConnected;
    if (!self.spdyNegotiated) {
      SPDY_LOG(@"%p spdy not negotiated", self);
      [self notSpdyError];
      [self invalidateSocket];
      return -1;
    }

    SPDY_LOG(@"%p invalidating connectionTimer", self);
    [connectionTimer invalidate];
    connectionTimer = nil;

    spdylay_session_client_new(&session, self.spdyVersion, callbacks, (__bridge void *)(self));

    @synchronized(streams) {
      NSEnumerator *enumerator = [streams objectEnumerator];
      SpdyStream * stream;        

      while ((stream = [enumerator nextObject])) {
	if (![self submitRequest:stream]) {
	  SPDY_LOG(@"%p submitRequest failed", self);
	  [streams removeObject:stream];
	}
      }
    }
    SPDY_LOG(@"%p Reused session: %ld", self, SSL_session_reused(ssl));
    return SSL_HANDSHAKE_SUCCESS;
  }
  if (r < 1) {
    /*
      ERROR RETURN VALUES
      
      0

      The TLS/SSL handshake was not successful but was shut down controlled and by the specifications of the TLS/SSL protocol. Call SSL_get_error() with the return value ret to find out the reason.

      <0

      The TLS/SSL handshake was not successful, because a fatal error occurred either at the protocol level or a connection failure occurred. The shutdown was not clean. It can also occur of action is need to continue the operation for non-blocking BIOs. Call SSL_get_error() with the return value ret to find out the reason.

    */

#ifdef CONF_Debug
    ERR_load_ERR_strings();
#endif

    //SPDY_LOG(@"NOT connected, r == %d", r);
    NSInteger oldErrno = errno;
    NSInteger err = SSL_get_error(ssl, r);
    
    BOOL again = NO;
    
    switch(err) {
    case SSL_ERROR_NONE:
      SPDY_LOG(@"%p SSL_ERROR_NONE", self);
      break;

    case SSL_ERROR_ZERO_RETURN:
      SPDY_LOG(@"%p SSL_ERROR_ZERO_RETURN", self);
      break;
      
    case SSL_ERROR_WANT_READ:
      //SPDY_LOG(@"%p SSL_ERROR_WANT_READ", self);
      again = YES;
      break;
      
    case SSL_ERROR_WANT_WRITE:
      SPDY_LOG(@"%p SSL_ERROR_WANT_WRITE", self);
      again = YES;
      break;
      
    case SSL_ERROR_WANT_CONNECT:
      SPDY_LOG(@"%p SSL_ERROR_WANT_CONNECT", self);
      again = YES;
      break;
      
    case SSL_ERROR_WANT_ACCEPT:
      SPDY_LOG(@"%p SSL_ERROR_WANT_ACCEPT", self);
      again = YES;
      break;
      
    case SSL_ERROR_WANT_X509_LOOKUP:
      SPDY_LOG(@"%p SSL_ERROR_WANT_X509_LOOKUP", self);
      again = YES;
      break;

    case SSL_ERROR_SYSCALL:
      SPDY_LOG(@"%p SSL_ERROR_SYSCALL", self);
      break;

    case SSL_ERROR_SSL:
      SPDY_LOG(@"%p SSL_ERROR_SSL", self);
      break;
    }
    if(r < 0 && !again) {
      //SPDY_LOG(@"%p calling error callback", self);
      self.connectState = kSpdyConnectStateError;
      if (err == SSL_ERROR_SYSCALL)
	[self connectionFailed:oldErrno domain:(NSString *)kCFErrorDomainPOSIX];
      else
	[self connectionFailed:err domain:kOpenSSLErrorDomain];
    } else {
      //SPDY_LOG(@"%p NOT calling error callback", self);
    }
    return again ? SSL_HANDSHAKE_NEED_TO_RETRY : -2;
  }
  return -666;
}

-(void)releaseDispatchSources {
  if(!write_source_enabled) {
    // if we cancel a suspended dispatch source, badness ensues
    dispatch_resume(write_source);
    write_source_enabled = YES;
  }

  if(read_source != NULL) {
    dispatch_source_cancel(read_source);
    read_source = NULL;
  }
  if(write_source != NULL) {
    dispatch_source_cancel(write_source);
    write_source = NULL;
  }
}

-(void)releaseStreams {
  if(self.readStream != NULL) {
    SPDY_LOG(@"%p closing and releasing read stream", self); 
    CFReadStreamClose(self.readStream);
    CFRelease(self.readStream);
    self.readStream = NULL;
    SPDY_LOG(@"%p done with read stream", self); 
  }
  if(self.writeStream != NULL) {
    CFWriteStreamClose(self.writeStream);
    CFRelease(self.writeStream);
    self.writeStream = NULL;
  }
}

-(void)sendVoipError {
  NSError * error = [NSError errorWithDomain:kSpdyErrorDomain
			     code:kSpdyVoipRequestedButFailed 
			     userInfo:nil];
  
  @synchronized(streams) {
    for (SpdyStream *value in streams) {
      [value.delegate onError:error];
    }
  }
}

- (void)setUpSSL {
  // Create SSL context.
  int sock = CFSocketGetNative(socket);
  make_non_block(sock);  // Ensure the SSL methods will not block.
  ssl = SSL_new(ssl_ctx);
  if (ssl == NULL) {
    [self sslError];
    return;
  }
  SSL_set_tlsext_host_name(ssl, [[self.host host] UTF8String]);
  if (SSL_set_fd(ssl, sock) == 0) {
    [self sslError];
    return;
  }
  SSL_set_app_data(ssl, (__bridge void*)self);
  if (oldSslSession) {
    SSL_set_session(ssl, oldSslSession);
    SSL_SESSION_free(oldSslSession);  // Reference taken in getSslSession.
    oldSslSession = NULL;
  }
}

-(BOOL) sslHandshakeWrapper {
  return [self sslHandshake] == SSL_HANDSHAKE_SUCCESS;
}

- (BOOL)sslConnect {
  [self setUpSSL];
  return [self sslHandshakeWrapper];
}

- (NSError *)connect:(NSURL *)h {
  SPDY_LOG(@"%p connect:%@", self, h);
  self.host = h;
  return [self connectTo:h];
}

- (void)addStream:(SpdyStream *)stream {
  SPDY_LOG(@"%p addStream:%p", self, stream);
  stream.parentSession = self;
  @synchronized(streams) {
    [streams addObject:stream];
    SPDY_LOG(@"%p after addStream, we have %lu streams", self, (unsigned long)streams.count);
  }
  if (self.connectState == kSpdyConnectStateConnected) {
    if (![self submitRequest:stream]) {
      SPDY_LOG(@"%p not able to submit request", self);
      return;
    }
    int err = spdylay_session_send(self.session);
    if (err != 0) {
      SPDY_LOG(@"%p Error (%d) sending data for %@", self, err, stream);
    }
  } else {
    SPDY_LOG(@"%p Post-poning %@ until a connection has been established, current state %d", self, stream, self.connectState);
  }
}
    
- (void)addPushStream:(SpdyStream *)stream {
  stream.parentSession = self;
  [pushStreams setObject:stream forKey:STREAM_KEY(stream.streamId)];
}

- (void)fetch:(NSURL *)u delegate:(SpdyCallback *)delegate {
  SPDY_LOG(@"%p fetch: delegate: body:", self);
  SpdyStream *stream = [SpdyStream newFromNSURL:u delegate:delegate];
  [self addStream:stream];
}

- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate body:(NSInputStream *)body {
  SPDY_LOG(@"%p fetchFromMessage: delegate: body:", self);
  SpdyStream *stream = [SpdyStream newFromCFHTTPMessage:request delegate:delegate body:body];
  [self addStream:stream];
}

- (void)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate {
  SPDY_LOG(@"%p fetchFromRequest: delegate:", self);
  SpdyStream *stream = [SpdyStream newFromRequest:(NSURLRequest *)request delegate:delegate];
  [self addStream:stream];
}

- (int)recv_data:(uint8_t *)data len:(size_t)len flags:(int)flags {
  int ret = SSL_read(ssl, data, (int)len);
  SPDY_LOG(@"%p readCallback is %@", self, self.readCallback);
  if(ret != 0 && self.readCallback != nil) self.readCallback(ret);
  return ret;
}

- (BOOL)wouldBlock:(int)sslError {
  return sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE;
}

- (ssize_t)fixUpCallbackValue:(int)r {

  if (r > 0)
    return r;

  int sslError = SSL_get_error(ssl, r);
  if (r < 0 && [self wouldBlock:sslError]) {
    r = SPDYLAY_ERR_WOULDBLOCK;
  } else {
    int sysError = sslError;
    if (sslError == SSL_ERROR_SYSCALL) {
      sysError = (int)ERR_get_error();
      if (sysError == 0) {
	if (r == 0)
	  sysError = -1;
	else
	  sysError = errno;
      }
    }
    SPDY_LOG(@"%p SSL Error %d, System error %d, retValue %d, closing connection", self, sslError, sysError, r);
    SPDY_LOG(@"%p on SSL ERROR, we have %lu streams and connect state %@", self, (unsigned long)streams.count, [SPDY connectionStateString:self.connectState]);
    r = SPDYLAY_ERR_CALLBACK_FAILURE;
    [self connectionFailed:ECONNRESET domain:(NSString *)kCFErrorDomainPOSIX];
    //[self invalidateSocket];
  }

  // Clear any errors that we could have encountered.
  ERR_clear_error();
  return r;
}

static ssize_t recv_callback(spdylay_session *session, uint8_t *data, size_t len, int flags, void *user_data) {
  //SPDY_LOG(@"%p recv_callback", self);
  SpdySession *ss = (__bridge SpdySession *)user_data;
  int r = [ss recv_data:data len:len flags:flags];
  return [ss fixUpCallbackValue:r];
}

- (int)send_data:(const uint8_t *)data len:(size_t)len flags:(int)flags {

  // this is in case we can't write all the data right now
  if(!write_source_enabled && write_source != nil) {
    dispatch_resume(write_source); 
    write_source_enabled = YES;
  }

  int ret = SSL_write(ssl, data, (int)len);
  SPDY_LOG(@"%p writeCallback is %@", self, self.writeCallback);
  if(ret != 0 && self.writeCallback != nil) {
    self.writeCallback((int)len);
  }
  return ret;
}

+(NSString*)formatData:(const uint8_t *)data length:(size_t)len {
  NSMutableString * ret = [[NSMutableString alloc] init];
  for(int i = 0 ; i < len ; i++) {
    uint8_t byte = data[i];
    if(byte >= 32 && byte < 127)
      [ret appendFormat:@"%c", (char)byte];
    else
      [ret appendFormat:@"[%02x]", (unsigned int)byte];
  }
  return ret;
}

static ssize_t send_callback(spdylay_session *session, const uint8_t *data, size_t len, int flags, void *user_data) {
  SPDY_LOG(@"send_callback (flags %d) (%zd bytes): %@", 
	   flags, len, [SpdySession formatData:data length:len]);

  SpdySession *ss = (__bridge SpdySession*)user_data;
  int r = [ss send_data:data len:len flags:flags];
  return [ss fixUpCallbackValue:r];
}

static void on_ctrl_recv_parse_error_callback(spdylay_session *session, 
					      spdylay_frame_type type,
					      const uint8_t *head, size_t headlen,
					      const uint8_t *payload, size_t payloadlen,
					      int error_code, void *user_data) {
  SPDY_LOG(@"on_ctrl_recv_parse_error_callback: spdylay_frame_type %d error_code %d", type, error_code);
}

static void on_invalid_ctrl_recv_callback(spdylay_session *session, 
					  spdylay_frame_type type, 
					  spdylay_frame *frame,
					  uint32_t status_code, void *user_data) {
  SPDY_LOG(@"on_invalid_ctrl_recv_callback: spdylay_frame_type %d status_code %d", 
	   type, status_code);
}

static void on_unknown_ctrl_recv_callback(spdylay_session *session,
					  const uint8_t *head, size_t headlen,
					  const uint8_t *payload, 
					  size_t payloadlen,
					  void *user_data) {
  SPDY_LOG(@"on_unknown_ctrl_recv_callback");
}

static void on_data_chunk_recv_callback(spdylay_session *session, uint8_t flags, int32_t stream_id,
                                        const uint8_t *data, size_t len, void *user_data) {

  SPDY_LOG(@"on_data_chunk_recv_callback (flags %d) (%zd bytes): %@", 
	   flags, len, [[NSData alloc] initWithBytes:data length:len]);
  SPDY_LOG(@"response is %@", [[NSString alloc] initWithData:[[NSData alloc] initWithBytes:data length:len] encoding:NSUTF8StringEncoding]);

  SpdyStream *stream = get_stream_for_id(session, stream_id, user_data);
  if(stream != nil) {
    [stream writeBytes:data len:len];
  } else {
    SPDY_LOG(@"unhandled stream in on_data_chunk_recv_callback");
  }
}

static void on_stream_close_callback(spdylay_session *session, int32_t stream_id, spdylay_status_code status_code, void *user_data) {
  //SPDY_LOG(@"on_stream_close_callback");
  SpdyStream *stream = get_stream_for_id(session, stream_id, user_data);
  if(stream != nil) {
    SPDY_LOG(@"Stream closed %@, because spdylay_status_code=%d", stream, status_code);
    [stream closeStream];
    SpdySession *ss = (__bridge SpdySession *)user_data;
    [ss removeStream:stream];
  } else {
    SPDY_LOG(@"unhandled stream in on_stream_close_callback");
  }
}

static void on_ctrl_recv_callback(spdylay_session *session, spdylay_frame_type type, spdylay_frame *frame, void *user_data) {
  //SPDY_LOG(@"on_ctrl_recv_callback type %d", type);
  if (type == SPDYLAY_SYN_REPLY) {
    spdylay_syn_reply *reply = &frame->syn_reply;
    SpdyStream *stream = get_stream_for_id(session, reply->stream_id, user_data);
    if(stream != nil) {
      [stream parseHeaders:(const char **)reply->nv];
    } else {
      SPDY_LOG(@"unhandled stream in on_ctrl_recv_callback");
    }
  } else if (type == SPDYLAY_SYN_STREAM) {
    spdylay_syn_stream *syn = &frame->syn_stream;
    int32_t stream_id = syn->stream_id;
    int32_t assoc_stream_id = syn->assoc_stream_id;
	
    if(assoc_stream_id == 0) {
      SPDY_LOG(@"ignoring server push w/ associated stream id 0");
    } else {
      SpdyStream *assoc_stream = get_stream_for_id(session, assoc_stream_id, user_data);
      if(assoc_stream == nil) {
	SPDY_LOG(@"ignoring server push w/ nil associated stream");
      } else {
	SpdyStream *push_stream = [SpdyStream newFromAssociatedStream:assoc_stream 
					      streamId:stream_id
					      nameValues:syn->nv];

	[assoc_stream.parentSession addPushStream:push_stream];
	[push_stream parseHeaders:(const char **)syn->nv];
      }
    } 
  } else if(type == SPDYLAY_SETTINGS) {
    spdylay_settings *settings = &frame->settings;
    for(int i = 0 ; i < settings->niv ; i++) {
      //spdylay_settings_entry * entry = settings->iv + i;
      //SPDY_LOG(@"settings entry id %d flags %d value %d", entry->settings_id, entry->flags, entry->value);
    }
  } else if(type == SPDYLAY_PING) {
    SpdySession * spdySession = (__bridge SpdySession*)user_data;
    [spdySession onPingReceived];
  } else if(type == SPDYLAY_GOAWAY) {
    SpdySession * spdySession = (__bridge SpdySession*)user_data;
    [spdySession onGoAwayReceived];
  }
}

static void before_ctrl_send_callback(spdylay_session *session, spdylay_frame_type type, spdylay_frame *frame, void *user_data) {
  //SPDY_LOG(@"before_ctrl_send_callback type %d", type);
  if (type == SPDYLAY_SYN_STREAM) {
    spdylay_syn_stream *syn = &frame->syn_stream;
    SpdyStream *stream = get_stream_for_id(session, syn->stream_id, user_data);
    if(stream != nil) {
      [stream setStreamId:syn->stream_id];
      //SPDY_LOG(@"Sending SYN_STREAM for %@", stream);
      [stream.delegate onConnect:stream];
    } else {
      SPDY_LOG(@"unhandled stream in on_ctrl_recv_callback");
    }
  }
}

- (void)removeStream:(SpdyStream *)stream {
  @synchronized(streams) {
    SPDY_LOG(@"%p removeStream:%p", self, stream);
    [streams removeObject:stream];
    [pushStreams removeObjectForKey:STREAM_KEY(stream.streamId)];
    SPDY_LOG(@"%p after removeStream, we have %lu streams", self, (unsigned long)streams.count);
  }
}

- (SpdySession *)init:(SSL_CTX *)ssl_context oldSession:(SSL_SESSION *)oldSession {
  self = [super init];
  if(self) {
    SPDY_LOG(@"%p init", self);
    ssl_ctx = ssl_context;
    oldSslSession = oldSession;
    
    SSL_CTX_set_timeout(ssl_context, 1200);

    callbacks = malloc(sizeof(*callbacks));
    memset(callbacks, 0, sizeof(*callbacks));
    callbacks->send_callback = send_callback;
    callbacks->recv_callback = recv_callback;
    callbacks->on_stream_close_callback = on_stream_close_callback;
    callbacks->on_ctrl_recv_callback = on_ctrl_recv_callback;
    callbacks->before_ctrl_send_callback = before_ctrl_send_callback;
    callbacks->on_data_chunk_recv_callback = on_data_chunk_recv_callback;
    callbacks->on_ctrl_recv_parse_error_callback = on_ctrl_recv_parse_error_callback;
    callbacks->on_unknown_ctrl_recv_callback = on_unknown_ctrl_recv_callback;
    callbacks->on_invalid_ctrl_recv_callback = on_invalid_ctrl_recv_callback;

    session = NULL;
    self.spdyNegotiated = NO;
    self.spdyVersion = -1;
    self.connectState = kSpdyConnectStateNotConnected;
    
    streams = [[NSMutableSet alloc] init];
    pushStreams = [[NSMutableDictionary alloc] init];
  }
  return self;
}
 
- (int)sendPingWithCallback:(void (^)())callback {
  pingCallback = callback;
  return [self sendPing];
}

- (int)sendPing {
  int ret = -1;
  if (session != NULL) 
    ret = spdylay_submit_ping(session);
  if(ret == 0)
    spdylay_session_send(session);

  SPDY_LOG(@"%p sendPing w/ session %p returning %d", self, session, ret);
  return ret;
}

- (void)onPingReceived {
  if(pingCallback != nil) 
    pingCallback();
}

- (void)onGoAwayReceived {
  SPDY_LOG(@"%p onGoAwayReceived", self);
  self.connectState = kSpdyConnectStateGoAwayReceived;
  [self invalidateSocket];
}

- (void)dealloc {
  SPDY_LOG(@"%p session dealloc", self);
  if (session != NULL) {
    SPDY_LOG(@"%p submitting goaway", self);
    self.connectState = kSpdyConnectStateGoAwaySubmitted;
    spdylay_submit_goaway(session, SPDYLAY_GOAWAY_OK);
    spdylay_session_del(session);
    session = NULL;
  }
  if (ssl != NULL) {
    SSL_shutdown(ssl);
    SSL_free(ssl);
  }
  [self invalidateSocket];
  free(callbacks);
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ host: %@, spdyVersion=%d, state=%d, networkStatus: %d", [super description], host, self.spdyVersion, self.connectState, self.networkStatus];
}

-(void)maybeEnableVoip {
  if(self.voip) {
    // these streams are only used for wakeup, all acutal i/o 
    // happens via the socket and openssl.
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;

    CFStreamCreatePairWithSocket(NULL, CFSocketGetNative(socket), 
				 &readStream, &writeStream);

    self.readStream = readStream;
    self.writeStream = writeStream;

    CFReadStreamSetProperty(self.readStream, 
			    kCFStreamNetworkServiceType, 
			    kCFStreamNetworkServiceTypeVoIP);
    CFWriteStreamSetProperty(self.writeStream, 
			     kCFStreamNetworkServiceType, 
			     kCFStreamNetworkServiceTypeVoIP); 

    CFReadStreamScheduleWithRunLoop(self.readStream, 
				    CFRunLoopGetCurrent(),
				    kCFRunLoopCommonModes);

    CFWriteStreamScheduleWithRunLoop(self.writeStream, 
				     CFRunLoopGetCurrent(),
				     kCFRunLoopCommonModes);

    if ( ! CFReadStreamOpen(self.readStream) || 
	 ! CFWriteStreamOpen(self.writeStream)) {
      [self releaseStreams];
      [self sendVoipError];
    }
  }
}

-(BOOL)sessionConnect {
  self.lastCallbackTime = [NSDate date];

  if (self.connectState == kSpdyConnectStateConnecting) {
    SPDY_LOG(@"%p Connected", self);
    self.connectState = kSpdyConnectStateSslHandshake;
    [self maybeEnableVoip];
    if (![self sslConnect]) {
      SPDY_LOG(@"%p ssl connect failed", self);
      return NO;
    }
  }
  if (self.connectState == kSpdyConnectStateSslHandshake) {
    //SPDY_LOG(@"doing ssl handshake", self);
    if(![self sslHandshakeWrapper]) {
      //SPDY_LOG(@"ssl handshake failed", self);
      return NO;
    } else {
      SPDY_LOG(@"%p ssl handshake succeeded", self);
    }
  }
  return YES;
}
 
-(void)sessionRead {
  if([self sessionConnect]) {
    spdylay_session *laySession = [self session];
    if(laySession == NULL) {
      SPDY_LOG(@"%p spdylay session is null!!", self);
    } else {
      spdylay_session_recv(laySession);
    }
  }
}

-(void)sessionWrite {
  if([self sessionConnect]) {
    spdylay_session *laySession = [self session];
    if(laySession == NULL) {
      SPDY_LOG(@"%p spdylay session is null!!", self);
    } else {
      size_t outbound_queue_size = 
	spdylay_session_get_outbound_queue_size(laySession);
 
      if(outbound_queue_size > 0) {
	int err = spdylay_session_send(laySession);
	if (err != 0) {
	  SPDY_LOG(@"%p Error writing data in write callback for session %@", self, session);
	}
      } else if(write_source != NULL) {
	// disable write interest when outbound queue is empty (otherwise we loop)
	dispatch_suspend(write_source);
	write_source_enabled = NO;
      }
    }
  }
}

@end

