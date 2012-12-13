//
//  SpdySession.h
//  SPDY library.  This file contains a class for a spdy session (a network connection).
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

#import <Foundation/Foundation.h>
#include "openssl/ssl.h"
#include "SpdyRequest.h"
#include "SPDY.h"

@class SpdyCallback;
@class SpdyStream;

struct spdylay_session;

@interface SpdySession : NSObject {
  struct spdylay_session *session;
    
  BOOL spdyNegotiated;
  SpdyConnectState connectState;
  SpdyNetworkStatus networkStatus;
  void (^pingCallback)();
}

@property (assign) BOOL spdyNegotiated;
@property (assign) uint16_t spdyVersion;
@property (assign) struct spdylay_session *session;
@property (strong) NSURL *host;
@property (assign) BOOL voip;
@property (assign) SpdyConnectState connectState;
@property (assign) SpdyNetworkStatus networkStatus;

// these are intended for debugging
@property (nonatomic,copy) SpdyIntCallback connectionStateCallback;
@property (nonatomic,copy) SpdyIntCallback writeCallback;
@property (nonatomic,copy) SpdyIntCallback readCallback;

- (SpdySession *)init:(SSL_CTX *)ssl_ctx oldSession:(SSL_SESSION *)oldSession;

// Returns nil if the session is able to start a connection to host.
- (NSError *)connect:(NSURL *)host;
- (void)fetch:(NSURL *)path delegate:(SpdyCallback *)delegate;
- (void)fetchFromMessage:(CFHTTPMessageRef)request delegate:(SpdyCallback *)delegate body:(NSInputStream *)body;
- (void)fetchFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate;
- (int)sendPing;
- (int)sendPingWithCallback:(void (^)())callback;
- (void)onPingReceived;
- (void)onGoAwayReceived;

- (NSInteger)resetStreamsAndGoAway;
- (SSL_SESSION *)getSslSession;


// Indicates if the session has entered an invalid state.
- (BOOL)isInvalid;

// Used by the SpdyStream
- (void)cancelStream:(SpdyStream *)stream;

@end
