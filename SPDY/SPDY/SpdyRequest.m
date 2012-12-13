#import "SpdyRequest.h"
#import "SpdyRequest+Private.h"
#import "SpdyHTTPResponse.h"
#import "SpdyRequestCallback.h"
#import "SpdySession.h"
#import "SPDY.h"

@implementation SpdyRequest {
  SpdyRequestCallback * delegate;
  NSURLRequest *  ns_url_request;
  NSString * urlString;
  BOOL tearing_down;
}

- (BOOL)tearingDown {
  return tearing_down;
}

-(NSString*)urlString {
  if(ns_url_request == nil) {
    return urlString;
  } else {
    return ns_url_request.URL.absoluteString;
  }
}

-(SpdyNetworkStatus)networkStatus {
  __block SpdyNetworkStatus ret = -1;
  void (^block)() = ^{
    if(ns_url_request == nil) {
      ret = [[SPDY sharedSPDY] networkStatusForUrlString:urlString];
    } else {
      ret = [[SPDY sharedSPDY] networkStatusForRequest:ns_url_request];
    }
  };
  __spdy_dispatchSync(block);
  return ret;
}

-(SpdyConnectState)connectState {
  __block SpdyConnectState ret = -1;
  void (^block)() = ^{
    if(ns_url_request == nil) {
      ret = [[SPDY sharedSPDY] connectStateForUrlString:urlString];
    } else {
      ret = [[SPDY sharedSPDY] connectStateForRequest:ns_url_request];
    }
  };
  __spdy_dispatchSync(block);
  return ret;
}

- (void)sendPing {
  // make sure the ping callback happens on the main thread
  SpdyVoidCallback glue = ^ {	
    __spdy_dispatchAsyncOnMainThread(self.pingCallback);
  };
  void (^block)() = ^{
    if(ns_url_request == nil) {
      [[SPDY sharedSPDY] pingUrlString:urlString callback:glue];
    } else {
      [[SPDY sharedSPDY] pingRequest:ns_url_request callback:glue];
    }
  };
  __spdy_dispatchAsync(block);
}

-(void)send {
  void (^block)() = ^{
    SpdySession * session = nil;
    if(ns_url_request == nil) {
      SPDY_LOG(@"WTF?");
      session = [[SPDY sharedSPDY] fetch:urlString delegate:delegate voip:_voip];
    } else {
      SPDY_LOG(@"WTF2?");
      session = [[SPDY sharedSPDY] fetchFromRequest:ns_url_request delegate:delegate voip:_voip];
    }
    SPDY_LOG(@"sending w/ self.connectionStateCallback %@ self.readCallback %@ self.writeCallback %@", self.connectionStateCallback, self.readCallback, self.writeCallback);
    if(self.connectionStateCallback != nil)
      session.connectionStateCallback = self.connectionStateCallback;
    if(self.readCallback != nil)
      session.readCallback = self.readCallback;
    if(self.writeCallback != nil)
      session.writeCallback = self.writeCallback;
  };
  __spdy_dispatchAsync(block);
}

- (void)teardown {
  void (^block)() = ^{
    SPDY_LOG(@"teardown");
    tearing_down = YES;
    if(ns_url_request == nil) {
      [[SPDY sharedSPDY] teardown:urlString];
    } else {
      [[SPDY sharedSPDY] teardownForRequest:ns_url_request];
    }
    tearing_down = NO;
  };
  __spdy_dispatchAsync(block);
}

- (id)initWithGETString:(NSString *)_urlString {
  self = [super init];
  if(self) {
    delegate = [[SpdyRequestCallback alloc] init:self];
    urlString = _urlString;
    tearing_down = NO;
    self.URL = [[NSURL alloc] initWithString:urlString];
  }
  return self;
}

- (id)initWithRequest:(NSURLRequest *)request {
  self = [super init];
  if(self) {
    delegate = [[SpdyRequestCallback alloc] init:self];
    ns_url_request = request;
    tearing_down = NO;
    self.URL = request.URL;
  }
  return self;
}

@end

// XXX move this
@implementation SpdyTimer {
  void (^block)();
  BOOL valid;
  NSTimeInterval interval;
}
-(id)initWithInterval:(NSTimeInterval)_interval andBlock:(void(^)())_block {
  self = [super init];
  if(self) {
    block = _block;
    interval = _interval;
    valid = YES;
  }
  return self;
}
-(void)start {
  if(valid) {
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW,
					 (int64_t)(interval*1000000000.0)); // nanosec
    dispatch_after(when, __spdy_dispatch_queue(), ^{
		     if(valid) { 
		       block(); 
		       valid = NO;
		     }
		   });
  }
}
-(void)invalidate {
  valid = NO;
}
@end
// XXX move this
