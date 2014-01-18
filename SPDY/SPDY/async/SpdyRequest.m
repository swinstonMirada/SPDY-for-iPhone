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

-(void)clearConnectionStatus {
  SPDY_LOG(@"%p _isConnecting = NO;", self);
  _isConnecting = NO;
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
    if(ns_url_request == nil) {
      _session = [[SPDY sharedSPDY] fetch:urlString delegate:delegate voip:_voip];
    } else {
      _session = [[SPDY sharedSPDY] fetchFromRequest:ns_url_request delegate:delegate voip:_voip];
    }
    SPDY_LOG(@"sending w/ self.connectionStateCallback %@ self.readCallback %@ self.writeCallback %@ and session %p", self.connectionStateCallback, self.readCallback, self.writeCallback, _session);
    if(_session == nil) {
      SPDY_LOG(@"session is nil, can't send");
    } else {
      SPDY_LOG(@"connectionStateCallback is %@", self.connectionStateCallback);
      if(self.connectionStateCallback != nil) {
        _session.connectionStateCallback = ^(NSString * session_, SpdyConnectState arg) {
          SPDY_LOG(@"%p _isConnecting = NO;", self);
          _isConnecting = NO;
          __spdy_dispatchAsyncOnMainThread(^{ self.connectionStateCallback(session_, arg); });
        };
        __spdy_dispatchAsyncOnMainThread(^{ self.connectionStateCallback(SPDY_SESSION_STATE_KEY(_session), _session.connectState); });
      } else {
        _session.connectionStateCallback = ^(NSString * session, SpdyConnectState arg) {
          SPDY_LOG(@"%p _isConnecting = NO;", self);
          _isConnecting = NO;
        };
      }
      if(self.readCallback != nil) {
        _session.readCallback = ^(int arg) {
          __spdy_dispatchAsyncOnMainThread(^{ self.readCallback(arg); });
        };
      }
      if(self.writeCallback != nil) {
        _session.writeCallback = ^(int arg) {
          __spdy_dispatchAsyncOnMainThread(^{ self.writeCallback(arg); });
        };
      }
      if(self.networkStatusCallback != nil) {
        _session.networkStatusCallback = ^(SpdyNetworkStatus arg) {
          __spdy_dispatchAsyncOnMainThread(^{ self.networkStatusCallback(arg); });
        };
        _session.networkStatusCallback(_session.networkStatus);
      }
    }
  };
  SPDY_LOG(@"%p _isConnecting = YES;", self);
  _isConnecting = YES;
  
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

