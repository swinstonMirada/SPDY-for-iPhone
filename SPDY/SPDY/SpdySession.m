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

#define STREAM_KEY(streamId) [NSString stringWithFormat:@"%d", streamId]

static const int priority = 1;

@interface SpdySession ()

#define SSL_HANDSHAKE_SUCCESS 0
#define SSL_HANDSHAKE_NEED_TO_RETRY 1

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

  self.connectState = kSpdyNotConnected;

  CFSocketInvalidate(socket);
  CFRelease(socket);
  [self releaseStreams];
  [self releaseDispatchSources];
  socket = nil;
}

- (void)sslError {
  SPDY_LOG(@"%s", ERR_error_string(ERR_get_error(), 0));
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
    SPDY_LOG(@"unhandled stream in read_from_data_callback");
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
    //SPDY_LOG(@"got scheme %@", scheme);
    if([scheme isEqualToString:@"https"]) {
      snprintf(service, sizeof(service), "443");
      /* 
	 in theory, bare http could be supported.
	 in practice, we require tls / ssl / https.
	 
	 } else if([scheme isEqualToString:@"http"]) {
	 snprintf(service, sizeof(service), "80");
      */
    } else {
      self.connectState = kSpdyError;
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
  SPDY_LOG(@"Looking up hostname for %@", [url host]);
  int err = getaddrinfo([[url host] UTF8String], service, &hints, &res);
  if (err != 0) {
    NSError *error;
    if (err == EAI_SYSTEM) {
      error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    } else {
      error = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:err userInfo:nil];
    }
    SPDY_LOG(@"Error getting IP address for %@ (%@)", url, error);
    self.connectState = kSpdyError;
    return error;
  }

  struct addrinfo* rp = res;
  if (rp != NULL) {
    CFSocketContext ctx = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFDataRef address = CFDataCreate(NULL, (const uint8_t*)rp->ai_addr, rp->ai_addrlen);
    socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, NULL, &ctx);

    int sock = CFSocketGetNative(socket);

    if(read_source != NULL) dispatch_release(read_source);

    read_source = 
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 
			     0, __spdy_dispatch_queue());

    if(write_source != NULL) dispatch_release(write_source);

    write_source = 
      dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, sock, 
			     0, __spdy_dispatch_queue());

    dispatch_source_set_event_handler(read_source, ^{ [self sessionRead]; });
    dispatch_source_set_event_handler(write_source, ^{ [self sessionWrite]; });

    // we don't want to reference self here, because the ivar is NULLed out 
    // in releaseDispatchSources.  So we keep create a local copy for the blocks
    dispatch_source_t local_read_source = read_source;
    dispatch_source_t local_write_source = write_source;

    dispatch_block_t write_cancel_handler = ^{ 
      dispatch_release(local_write_source);
      close(sock); 
    };

    dispatch_block_t read_cancel_handler = ^{ 
      dispatch_release(local_read_source);
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
    self.connectState = kSpdyConnecting;
    freeaddrinfo(res);

    SPDY_LOG(@"%p starting connectionTimer", self);
    [connectionTimer invalidate];
    connectionTimer = [[SpdyTimer alloc] initWithInterval:12 // XXX hardcoded
					 andBlock:^{ [self connectionTimedOut]; }];
    [connectionTimer start];
    return nil;
  }
  self.connectState = kSpdyError;
  return [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
}

- (void)notSpdyError {
  self.connectState = kSpdyError;
    
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
  SPDY_LOG(@"%p invalidating connectionTimer", self);
  [connectionTimer invalidate];
  connectionTimer = nil;
  self.connectState = kSpdyError;
  [self invalidateSocket];
  NSError *error = [NSError errorWithDomain:domain code:err userInfo:nil];
  SPDY_LOG(@"we have %d streams", streams.count);
  @synchronized(streams) {
    for (SpdyStream *value in streams) {
      SPDY_LOG(@"sending error to delegate %@", value.delegate);
      [value.delegate onError:error];
    }
  }
}

- (void)_cancelStream:(SpdyStream *)stream {
  [stream cancelStream];
  if (stream.streamId > 0) {
    spdylay_submit_rst_stream([self session], stream.streamId, SPDYLAY_CANCEL);
  }
}

- (void)cancelStream:(SpdyStream *)stream {
  // Do not remove the stream here as it will be removed on the close callback when spdylay is done with the object.
  [self _cancelStream:stream];
}

- (NSInteger)resetStreamsAndGoAway {
  @synchronized(streams) {
    NSInteger cancelledStreams = [streams count];
    for (SpdyStream *stream in streams) {
      [self _cancelStream:stream];
    }
    self.connectState = kSpdyGoAwaySubmitted;
    if (session != nil) {
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
  
  SPDY_LOG(@"submit request");
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
    SPDY_LOG(@"Failed to submit request for %@", stream);
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
    SPDY_LOG(@"connected");
    self.connectState = kSpdyConnected;
    if (!self.spdyNegotiated) {
      SPDY_LOG(@"spdy not negotiated");
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
	  SPDY_LOG(@"submitRequest failed");
	  [streams removeObject:stream];
	}
      }
    }
    SPDY_LOG(@"Reused session: %ld", SSL_session_reused(ssl));
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
      SPDY_LOG(@"SSL_ERROR_NONE");
      break;

    case SSL_ERROR_ZERO_RETURN:
      SPDY_LOG(@"SSL_ERROR_ZERO_RETURN");
      break;
      
    case SSL_ERROR_WANT_READ:
      SPDY_LOG(@"SSL_ERROR_WANT_READ");
      again = YES;
      break;
      
    case SSL_ERROR_WANT_WRITE:
      SPDY_LOG(@"SSL_ERROR_WANT_WRITE");
      again = YES;
      break;
      
    case SSL_ERROR_WANT_CONNECT:
      SPDY_LOG(@"SSL_ERROR_WANT_CONNECT");
      again = YES;
      break;
      
    case SSL_ERROR_WANT_ACCEPT:
      SPDY_LOG(@"SSL_ERROR_WANT_ACCEPT");
      again = YES;
      break;
      
    case SSL_ERROR_WANT_X509_LOOKUP:
      SPDY_LOG(@"SSL_ERROR_WANT_X509_LOOKUP");
      again = YES;
      break;

    case SSL_ERROR_SYSCALL:
      SPDY_LOG(@"SSL_ERROR_SYSCALL");
      break;

    case SSL_ERROR_SSL:
      SPDY_LOG(@"SSL_ERROR_SSL");
      break;
    }
    if(r < 0 && !again) {
      //SPDY_LOG(@"calling error callback");
      self.connectState = kSpdyError;
      if (err == SSL_ERROR_SYSCALL)
	[self connectionFailed:oldErrno domain:(NSString *)kCFErrorDomainPOSIX];
      else
	[self connectionFailed:err domain:kOpenSSLErrorDomain];
    } else {
      //SPDY_LOG(@"NOT calling error callback");
    }
    return again ? SSL_HANDSHAKE_NEED_TO_RETRY : -2;
  }
  return -666;
}

-(void)releaseDispatchSources {
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
    SPDY_LOG(@"closing and releasing read stream"); 
    CFReadStreamClose(self.readStream);
    CFRelease(self.readStream);
    self.readStream = NULL;
    SPDY_LOG(@"done with read stream"); 
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
  SPDY_LOG(@"connect:%@", h);
  self.host = h;
  return [self connectTo:h];
}

- (void)addStream:(SpdyStream *)stream {
  stream.parentSession = self;
  @synchronized(streams) {
    [streams addObject:stream];
  }
  if (self.connectState == kSpdyConnected) {
    if (![self submitRequest:stream]) {
      SPDY_LOG(@"not able to submit request");
      return;
    }
    int err = spdylay_session_send(self.session);
    if (err != 0) {
      SPDY_LOG(@"Error (%d) sending data for %@", err, stream);
    }
  } else {
    SPDY_LOG(@"Post-poning %@ until a connection has been established, current state %d", stream, self.connectState);
  }
}
    
- (void)addPushStream:(SpdyStream *)stream {
  stream.parentSession = self;
  [pushStreams setObject:stream forKey:STREAM_KEY(stream.streamId)];
}

- (void)fetch:(NSURL *)u delegate:(SpdyCallback *)delegate {
  SpdyStream *stream = [SpdyStream newFromNSURL:u delegate:delegate];
  [self addStream:stream];
}

- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate body:(NSInputStream *)body {
  SpdyStream *stream = [SpdyStream newFromCFHTTPMessage:request delegate:delegate body:body];
  [self addStream:stream];
}

- (void)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate {
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
      sysError = ERR_get_error();
      if (sysError == 0) {
	if (r == 0)
	  sysError = -1;
	else
	  sysError = errno;
      }
    }
    SPDY_LOG(@"SSL Error %d, System error %d, retValue %d, closing connection", sslError, sysError, r);
    r = SPDYLAY_ERR_CALLBACK_FAILURE;
    [self connectionFailed:ECONNRESET domain:(NSString *)kCFErrorDomainPOSIX];
    [self invalidateSocket];
  }

  // Clear any errors that we could have encountered.
  ERR_clear_error();
  return r;
}

static ssize_t recv_callback(spdylay_session *session, uint8_t *data, size_t len, int flags, void *user_data) {
  //SPDY_LOG(@"recv_callback");
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

static ssize_t send_callback(spdylay_session *session, const uint8_t *data, size_t len, int flags, void *user_data) {
  SPDY_LOG(@"send_callback (flags %d) (%zd bytes): %@", 
	   flags, len, [[NSData alloc] initWithBytes:data length:len]);
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
    [streams removeObject:stream];
    [pushStreams removeObjectForKey:STREAM_KEY(stream.streamId)];
  }
}

- (SpdySession *)init:(SSL_CTX *)ssl_context oldSession:(SSL_SESSION *)oldSession {
  self = [super init];
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
  self.connectState = kSpdyNotConnected;
    
  streams = [[NSMutableSet alloc] init];
  pushStreams = [[NSMutableDictionary alloc] init];
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

  SPDY_LOG(@"sendPing w/ session %p returning %d", session, ret);
  return ret;
}

 - (void)onPingReceived {
  if(pingCallback != nil) 
    pingCallback();
}

- (void)onGoAwayReceived {
  self.connectState = kSpdyGoAwayReceived;
}

 - (void)dealloc {
  SPDY_LOG(@"%p dealloc", self);
  if (session != NULL) {
    self.connectState = kSpdyGoAwaySubmitted;
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
  if (self.connectState == kSpdyConnecting) {
    SPDY_LOG(@"Connected");
    self.connectState = kSpdySslHandshake;
    [self maybeEnableVoip];
    if (![self sslConnect]) {
      SPDY_LOG(@"ssl connect failed");
      return NO;
    }
  }
  if (self.connectState == kSpdySslHandshake) {
    SPDY_LOG(@"doing ssl handshake");
    if(![self sslHandshakeWrapper]) {
      SPDY_LOG(@"ssl handshake failed");
      return NO;
    } else {
      SPDY_LOG(@"ssl handshake succeeded");
    }
  }
  return YES;
}
 
-(void)sessionRead {
  if([self sessionConnect]) {
    spdylay_session *laySession = [self session];
    if(laySession == NULL) {
      SPDY_LOG(@"spdylay session is null!!");
    } else {
      spdylay_session_recv(laySession);
    }
  }
}

-(void)sessionWrite {
  if([self sessionConnect]) {
    spdylay_session *laySession = [self session];
    if(laySession == NULL) {
      SPDY_LOG(@"spdylay session is null!!");
    } else {
      size_t outbound_queue_size = 
	spdylay_session_get_outbound_queue_size(laySession);
 
      if(outbound_queue_size > 0) {
	int err = spdylay_session_send(laySession);
	if (err != 0) {
	  SPDY_LOG(@"Error writing data in write callback for session %@", session);
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

