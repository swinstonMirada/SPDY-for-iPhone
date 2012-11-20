#import "SpdyPersistentUrl.h"
#import <errno.h>
#import <netdb.h>

@implementation SpdyPersistentUrl {
  NSTimer * pingTimer;
  BOOL stream_closed;
}

-(void)reconnect:(NSError*)error {
  SPDY_LOG(@"reconnect:%@", error);

  // XXX make sure this is not a fatal error (e.g. host down, etc).
  if(error != nil) {
    if([error.domain isEqualToString:kSpdyErrorDomain]) {
      if(error.code == kSpdyConnectionFailed ||
	 error.code == kSpdyRequestCancelled ||
	 error.code == kSpdyConnectionNotSpdy ||
	 error.code == kSpdyInvalidResponseHeaders ||
	 error.code == kSpdyHttpSchemeNotSupported ||
	 error.code == kSpdyStreamClosedWithNoRepsonseHeaders) {
	// call fatal error callback
	if(self.fatalErrorCallback != nil) {
	  self.fatalErrorCallback(error);
	}
	return;
      }
    } else if([error.domain isEqualToString:NSPOSIXErrorDomain]) { 
      if(error.code == ECONNREFUSED || // connection refused
	 error.code == EHOSTDOWN || // host is down
	 error.code == EHOSTUNREACH || // no route to host 
	 error.code == EPFNOSUPPORT ||
	 error.code == ESOCKTNOSUPPORT ||
	 error.code == ENOTSUP ||
	 error.code == ENOTSOCK ||
	 error.code == EDESTADDRREQ ||
	 error.code == EMSGSIZE ||
	 error.code == EPROTOTYPE ||
	 error.code == ENOPROTOOPT
	 ) { 
	if(self.fatalErrorCallback != nil) {
	  self.fatalErrorCallback(error);
	}
	return;
      }
    } else if([error.domain isEqualToString:@"kCFStreamErrorDomainNetDB"]) { 
      if(error.code == HOST_NOT_FOUND || /* Authoritative Answer Host not found */
	 error.code == NO_RECOVERY || /* Non recoverable errors, FORMERR,REFUSED,NOTIMP*/
	 error.code == NO_DATA || /* Valid name, no data record of requested type */
	 error.code == EAI_ADDRFAMILY || /* address family for hostname not supported */
	 error.code == EAI_BADFLAGS || /* invalid value for ai_flags */
	 error.code == EAI_FAIL || /* non-recoverable failure in name resolution */
	 error.code == EAI_FAMILY || /* ai_family not supported */
	 error.code == EAI_NODATA || /* no address associated with hostname */
	 error.code == EAI_NONAME || /* hostname nor servname provided, or not known */
	 error.code == EAI_SERVICE || /* servname not supported for ai_socktype */
	 error.code == EAI_SOCKTYPE || /* ai_socktype not supported */
	 error.code == EAI_SYSTEM || /* system error returned in errno */
	 error.code == EAI_BADHINTS || /* invalid value for hints */
	 error.code == EAI_PROTOCOL || /* resolved protocol is unknown */
	 error.code == EAI_OVERFLOW /* argument buffer overflow */
	 ) { 
	if(self.fatalErrorCallback != nil) {
	  self.fatalErrorCallback(error);
	}
	return;
      }

    }

    // XXX add more cases here
  }
  SPDY_LOG(@"error is not fatal");

  // here we do reconnect logic
  SpdyNetworkStatus networkStatus = self.networkStatus;
  SpdyConnectState connectState = self.connectState;
  if(networkStatus == kSpdyNotReachable) {
    SPDY_LOG(@"not reachable");
    return;			// no point in connecting
  }

  if(!stream_closed && connectState == kSpdyConnected) {
    SPDY_LOG(@"already connected");
    return;			// already connected;
  }

  if(connectState == kSpdyConnecting || connectState == kSpdySslHandshake) {
    SPDY_LOG(@"connecting");
    return;			// may want to set a timeout for lingering connects
  }

  SPDY_LOG(@"doing reconnect");
  // we are reachable, and not connected, and the error is not fatal, reconnect
  
  [self doGET];
}

-(void)streamWasClosed {
  stream_closed = YES;
  [self reconnect:nil];
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
    stream_closed = NO;
    SpdyPersistentUrl * __unsafe_unretained unsafe_self = self;
    self.errorCallback = ^(NSError * error) {
      SPDY_LOG(@"errorCallback");
      [unsafe_self reconnect:error];
    };
    self.pingCallback = ^ {
      [unsafe_self gotPing];
    };
    self.streamCloseCallback = ^ {
      SPDY_LOG(@"streamCloseCallback");
      [unsafe_self streamWasClosed];
    };
  }
  return self;
}

@end
