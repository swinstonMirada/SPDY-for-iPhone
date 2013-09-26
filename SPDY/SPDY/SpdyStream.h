//
//  SpdyStream.h
//  A stream class the corresponds to an HTTP request and response.
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


#import <Foundation/Foundation.h>
#import "SPDY.h"

@class SpdyCallback;
@class SpdySession;

@interface SpdyStream : NSObject<SpdyRequestIdentifier> {
    const char **nameValues;

    BOOL streamClosed;
    SpdyCallback *delegate;
}

// To be used by the SPDY session.
- (void)parseHeaders:(const char **)nameValuePairs;
- (size_t)writeBytes:(const uint8_t *)data len:(size_t) length;
- (void)closeStream;
- (void)cancelStream;

// Close forwards back to the parent session.
- (void)close;

// Error case handlers used by the SPDY session.
- (void)notSpdyError;
- (void)connectionError;

+ (SpdyStream *)newFromCFHTTPMessage:(CFHTTPMessageRef)msg delegate:(SpdyCallback *)delegate body:(NSInputStream *)body;
+ (SpdyStream *)newFromNSURL:(NSURL *)url delegate:(SpdyCallback *)delegate;
+ (SpdyStream *)newFromRequest:(NSURLRequest *)request delegate:(SpdyCallback *)delegate;
+ (SpdyStream *)newFromAssociatedStream:(SpdyStream *)associatedStream streamId:(int32_t)streamId nameValues:(char**)nv;

+ (void)staticInit;

@property const char **nameValues;

@property (strong, nonatomic) SpdyCallback *delegate;
@property (strong, nonatomic) NSInputStream *body;
@property (assign, nonatomic) NSInteger streamId;
@property (strong, nonatomic) SpdySession *parentSession;

// If a stream is closed after the timeout the session should probably be closed.
@property (assign, nonatomic) NSTimeInterval streamTimeoutInterval;

@end


