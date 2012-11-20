#import "SpdyPersistentUrl.h"

@implementation SpdyPersistentUrl {
  NSTimer * pingTimer;
}

-(void)reconnect:(NSError*)error {
  // here we do reconnect logic
  SpdyNetworkStatus networkStatus = self.networkStatus;
  SpdyConnectState connectState = self.connectState;
  if(networkStatus == kSpdyNotReachable) 
    return;			// no point in connecting

  if(connectState == kSpdyConnected)
    return;			// already connected;

  if(connectState == kSpdyConnecting || connectState == kSpdySslHandshake)
    return;			// may want to set a timeout for lingering connects

  // we are reachable, and not connected, reconnect

  [self doGET];
}
-(void)gotPing {
  [pingTimer invalidate];
  pingTimer = nil;
}

-(void)noPingReceived {
  [pingTimer invalidate];
  pingTimer = nil;
  [self teardown];
  [self reconnect:nil];
}

-(void)sendPing {
  [super sendPing];
  pingTimer = [NSTimer timerWithTimeInterval:6 // XXX fudge this interval?
		       target:self selector:@selector(noPingReceived) 
		       userInfo:nil repeats:NO];
}

- (id)initWithUrlString:(NSString *)url {
  self = [super initWithUrlString:url];
  if(self) {
    self.voip = YES;
    SpdyPersistentUrl * __unsafe_unretained unsafe_self = self;
    self.errorCallback = ^(NSError * error) {
      [unsafe_self reconnect:error];
    };
    self.pingCallback = ^ {
      [unsafe_self gotPing];
    };
    self.streamCloseCallback = ^ {
      [unsafe_self reconnect:nil];
    };
  }
  return self;
}

@end
