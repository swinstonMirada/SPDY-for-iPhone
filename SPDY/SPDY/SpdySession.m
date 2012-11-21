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

#include "openssl/ssl.h"
#include "openssl/err.h"
#include "spdylay/spdylay.h"

#define STREAM_KEY(streamId) [NSString stringWithFormat:@"%d", streamId]

static void ReadStreamCallback(CFReadStreamRef stream,
			       CFStreamEventType eventType,
			       void *clientCallBackInfo);

static void WriteStreamCallback(CFWriteStreamRef stream,
				CFStreamEventType eventType,
				void *clientCallBackInfo);

static const int priority = 1;

@interface SpdySession ()

- (void)_cancelStream:(SpdyStream *)stream;
- (NSError *)connectTo:(NSURL *)url;
- (void)connectionFailed:(NSInteger)error domain:(NSString *)domain;
- (void)invalidateSocket;
- (void)removeStream:(SpdyStream *)stream;
- (int)send_data:(const uint8_t *)data len:(size_t)len flags:(int)flags;
- (BOOL)sslConnect;
- (BOOL)sslHandshake;  // Returns true if the handshake completed.
- (void)sslError;
- (BOOL)submitRequest:(SpdyStream *)stream;
- (BOOL)wouldBlock:(int)r;
- (ssize_t)fixUpCallbackValue:(int)r;
- (void)enableWriteCallback;

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
}

@synthesize spdyNegotiated;
@synthesize spdyVersion;
@synthesize session;
@synthesize host;
@synthesize voip;
@synthesize connectState;
@synthesize networkStatus;

static void sessionCallBack(CFSocketRef s,
                            CFSocketCallBackType callbackType,
                            CFDataRef address,
                            const void *data,
                            void *info);

- (SpdyStream*)pushStreamForId:(int32_t)stream_id {
  return [pushStreams objectForKey:STREAM_KEY(stream_id)];
}

- (void)invalidateSocket {
  if (socket == nil)
    return;

  CFSocketInvalidate(socket);
  CFRelease(socket);
  if(self.readStream != NULL) CFRelease(self.readStream);
  if(self.writeStream != NULL) CFRelease(self.writeStream);
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
    struct addrinfo hints;
    
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
    
    memset(&hints, 0, sizeof(struct addrinfo));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    
    struct addrinfo *res;
    //SPDY_LOG(@"Looking up hostname for %@", [url host]);
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
        socket = CFSocketCreate(NULL, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketConnectCallBack | kCFSocketReadCallBack | kCFSocketWriteCallBack,
                                &sessionCallBack, &ctx);
        CFSocketConnectToAddress(socket, address, -1);
        
        // Ignore write failures, and deal with then on write.
        int set = 1;
        int sock = CFSocketGetNative(socket);
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));

        
        CFRelease(address);
        self.connectState = kSpdyConnecting;
        freeaddrinfo(res);
        return nil;
    }
    self.connectState = kSpdyError;
    return [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil];
}

static void ReadStreamCallback(CFReadStreamRef stream,
			       CFStreamEventType eventType,
			       void *clientCallBackInfo)
{      
  SpdySession * session = (__bridge SpdySession*)clientCallBackInfo;
  spdylay_session *laySession = [session session];
  SPDY_LOG(@"read stream callback");
  
  switch (eventType)
  {
    case kCFStreamEventOpenCompleted:
      SPDY_LOG(@"kCFStreamEventOpenCompleted");
      spdylay_session_recv(laySession);
      break;

    case kCFStreamEventHasBytesAvailable:
      SPDY_LOG(@"kCFStreamEventHasBytesAvailable");
      spdylay_session_recv(laySession);
      break;

    case kCFStreamEventErrorOccurred:
      SPDY_LOG(@"kCFStreamEventErrorOccurred");
      break;

    case kCFStreamEventEndEncountered:
      SPDY_LOG(@"kCFStreamEventEndEncountered");
      break;

    default:
      break; // do nothing
  }
}

static void WriteStreamCallback(CFWriteStreamRef stream,
				CFStreamEventType eventType,
				void *clientCallBackInfo)
{
  SpdySession * session = (__bridge SpdySession*)clientCallBackInfo;
  spdylay_session *laySession = [session session];

  switch (eventType)
  {
    case kCFStreamEventOpenCompleted:
      {
	SPDY_LOG(@"kCFStreamEventOpenCompleted");
	int err = spdylay_session_send(laySession);
	if (err != 0) {
	  SPDY_LOG(@"Error writing data in write callback for session %@", session);
	}
      }
      break;

    case kCFStreamEventCanAcceptBytes:
      {
	SPDY_LOG(@"kCFStreamEventCanAcceptBytes");
	int err = spdylay_session_send(laySession);
	if (err != 0) {
	  SPDY_LOG(@"Error writing data in write callback for session %@", session);
	}
      }
      break;

    case kCFStreamEventErrorOccurred:
      SPDY_LOG(@"kCFStreamEventErrorOccurred");
      break;

    case kCFStreamEventEndEncountered:
      SPDY_LOG(@"kCFStreamEventEndEncountered");
      break;     

    default:
      break; // do nothing
  }
}



- (void)notSpdyError {
    self.connectState = kSpdyError;
    
    for (SpdyStream *stream in streams) {
        [stream notSpdyError];
    }
}

- (void)connectionFailed:(NSInteger)err domain:(NSString *)domain {
    self.connectState = kSpdyError;
    [self invalidateSocket];
    NSError *error = [NSError errorWithDomain:domain code:err userInfo:nil];
    for (SpdyStream *value in streams) {
        [value.delegate onError:error];
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
    NSInteger cancelledStreams = [streams count];
    for (SpdyStream *stream in streams) {
        [self _cancelStream:stream];
    }
    if (session != nil) {
        spdylay_submit_goaway(session, SPDYLAY_GOAWAY_OK);
        spdylay_session_send(session);
    }
    return cancelledStreams;
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

- (BOOL)sslHandshake {
    int r = SSL_connect(ssl);
    if (r == 1) {
        self.connectState = kSpdyConnected;
        if (!self.spdyNegotiated) {
            [self notSpdyError];
            [self invalidateSocket];
            return NO;
        }

        spdylay_session_client_new(&session, self.spdyVersion, callbacks, (__bridge void *)(self));

        NSEnumerator *enumerator = [streams objectEnumerator];
        SpdyStream * stream;
        

	SpdySession * _session_ = self;
	if(_session_.voip) {
	  SPDY_LOG(@"REALLY DOING VOIP");

	  CFReadStreamRef readStream = NULL;
	  CFWriteStreamRef writeStream = NULL;

	  CFStreamCreatePairWithSocket(NULL, CFSocketGetNative(socket), &readStream, &writeStream);

	  SPDY_LOG(@"read stream is %p write stream is %p", readStream, writeStream);

	  _session_.readStream = readStream;
	  _session_.writeStream = writeStream;

	  CFReadStreamSetProperty(_session_.readStream, 
				  kCFStreamNetworkServiceType, 
				  kCFStreamNetworkServiceTypeVoIP);
	  CFWriteStreamSetProperty(_session_.writeStream, 
				   kCFStreamNetworkServiceType, 
				   kCFStreamNetworkServiceTypeVoIP); 

	  int nFlags = kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	  CFStreamClientContext context;
	  context.info = (__bridge void*)_session_;
	  context.version = 0;
	  context.release = NULL;
	  context.retain = NULL;
	  context.copyDescription = NULL;

	  if ( !CFReadStreamSetClient(_session_.readStream, nFlags, ReadStreamCallback, &context) )
	    {
	      SPDY_LOG(@"HOLY FUCK");
	      //ReleaseStreams();
	      return NO;
	    }

	  if ( !CFWriteStreamSetClient(_session_.writeStream, nFlags, WriteStreamCallback, &context) )
	    {
	      SPDY_LOG(@"HOLY FUCK");
	      //ReleaseStreams();
	      return NO;
	    }

	  CFReadStreamScheduleWithRunLoop(_session_.readStream, 
					  CFRunLoopGetCurrent(),
					  kCFRunLoopCommonModes);

	  CFWriteStreamScheduleWithRunLoop(_session_.writeStream, 
					   CFRunLoopGetCurrent(),
					   kCFRunLoopCommonModes);

	  if ( ! CFReadStreamOpen(_session_.readStream) || 
	       ! CFWriteStreamOpen(_session_.writeStream)) {
	    SPDY_LOG(@"WE'RE fucked");
	  }

  	} else {
	  SPDY_LOG(@"**NOT** DOING VOIP");
	}



        while ((stream = [enumerator nextObject])) {
            if (![self submitRequest:stream]) {
	      [streams removeObject:stream];
            }
        }
        //SPDY_LOG(@"Reused session: %ld", SSL_session_reused(ssl));
        return YES;
    }
    if (r == 0) {
        self.connectState = kSpdyError;
        NSInteger oldErrno = errno;
        NSInteger err = SSL_get_error(ssl, r);
        if (err == SSL_ERROR_SYSCALL)
            [self connectionFailed:oldErrno domain:(NSString *)kCFErrorDomainPOSIX];
        else
            [self connectionFailed:err domain:kOpenSSLErrorDomain];
        [self invalidateSocket];
    }
    return NO;
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

- (BOOL)sslConnect {
    [self setUpSSL];
    return [self sslHandshake];
}



- (NSError *)connect:(NSURL *)h {
    self.host = h;
    return [self connectTo:h];
}

- (void)addStream:(SpdyStream *)stream {
    stream.parentSession = self;
    [streams addObject:stream];
    if (self.connectState == kSpdyConnected) {
        if (![self submitRequest:stream]) {
            return;
        }
        int err = spdylay_session_send(self.session);
        if (err != 0) {
            SPDY_LOG(@"Error (%d) sending data for %@", err, stream);
        }
    } else {
      //SPDY_LOG(@"Post-poning %@ until a connection has been established, current state %d", stream, self.connectState);
    }
}
    
- (void)addPushStream:(SpdyStream *)stream {
    stream.parentSession = self;
    [pushStreams setObject:stream forKey:STREAM_KEY(stream.streamId)];
}

- (void)fetch:(NSURL *)u delegate:(RequestCallback *)delegate {
    SpdyStream *stream = [SpdyStream newFromNSURL:u delegate:delegate];
    [self addStream:stream];
}

- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(RequestCallback *)delegate body:(NSInputStream *)body {
    SpdyStream *stream = [SpdyStream newFromCFHTTPMessage:request delegate:delegate body:body];
    [self addStream:stream];
}

- (void)fetchFromRequest:(NSURLRequest *)request delegate:(RequestCallback *)delegate {
    SpdyStream *stream = [SpdyStream newFromRequest:(NSURLRequest *)request delegate:delegate];
    [self addStream:stream];
}

- (void)addToLoop {
    CFRunLoopSourceRef loop_ref = CFSocketCreateRunLoopSource (NULL, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), loop_ref, kCFRunLoopCommonModes);
    CFRelease(loop_ref);
}

- (int)recv_data:(uint8_t *)data len:(size_t)len flags:(int)flags {
    return SSL_read(ssl, data, (int)len);
}

- (BOOL)wouldBlock:(int)sslError {
    return sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE;
}

- (ssize_t)fixUpCallbackValue:(int)r {
    [self enableWriteCallback];

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
    return SSL_write(ssl, data, (int)len);
}

- (void)enableWriteCallback {
    if (socket != NULL)
        CFSocketEnableCallBacks(socket, kCFSocketWriteCallBack | kCFSocketReadCallBack);    
}

static ssize_t send_callback(spdylay_session *session, const uint8_t *data, size_t len, int flags, void *user_data) {
  //SPDY_LOG(@"send_callback");
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
  //SPDY_LOG(@"on_data_chunk_recv_callback");
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
      //SPDY_LOG(@"Stream closed %@, because spdylay_status_code=%d", stream, status_code);
      [stream closeStream];
      SpdySession *ss = (__bridge SpdySession *)user_data;
      [ss removeStream:stream];
    } else {
      SPDY_LOG(@"unhandled stream in on_stream_close_callback");
    }
}

static void on_ctrl_recv_callback(spdylay_session *session, spdylay_frame_type type, spdylay_frame *frame, void *user_data) {
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
  [streams removeObject:stream];
  [pushStreams removeObjectForKey:STREAM_KEY(stream.streamId)];
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

  //SPDY_LOG(@"sendPing w/ session %p returning %d", session, ret);
  return ret;
}

- (void)onPingReceived {
  if(pingCallback != nil) 
    pingCallback();
}

- (void)dealloc {
    if (session != NULL) {
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
@end

static void sessionCallBack(CFSocketRef s,
                            CFSocketCallBackType callbackType,
                            CFDataRef address,
                            const void *data,
                            void *info) {
    //SPDY_DEBUG_LOG(@"Calling session callback: %p", info);
    if (info == NULL) {
        return;
    }
    SpdySession *session = (__bridge SpdySession *)info;
    if (session.connectState == kSpdyConnecting) {
        if (data != NULL) {
            int e = *(int *)data;
            [session connectionFailed:e domain:(NSString *)kCFErrorDomainPOSIX];
            return;
        }

        //SPDY_LOG(@"Connected to %@", info);
        session.connectState = kSpdySslHandshake;
        if (![session sslConnect]) {
            return;
        }
        callbackType |= kCFSocketWriteCallBack;
    }
    if (session.connectState == kSpdySslHandshake) {
        if (![session sslHandshake]) {
            return;
        }
        callbackType |= kCFSocketWriteCallBack;
    }

    spdylay_session *laySession = [session session];
    if (callbackType & kCFSocketWriteCallBack) {
        int err = spdylay_session_send(laySession);
        if (err != 0) {
            SPDY_LOG(@"Error writing data in write callback for session %@", session);
        }
    }
    if (callbackType & kCFSocketReadCallBack) {
        spdylay_session_recv(laySession);
    }
}


