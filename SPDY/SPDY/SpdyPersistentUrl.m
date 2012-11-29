#import "SpdyPersistentUrl.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <netdb.h>

@implementation SpdyPersistentUrl {
  NSTimer * pingTimer;
  BOOL stream_closed;
  SCNetworkReachabilityRef reachabilityRef;
  SpdyNetworkStatus networkStatus;
}


static void PrintReachabilityFlags(SCNetworkReachabilityFlags    flags)
{
	
  SPDY_LOG(@"Reachability Flag Status: %c%c %c%c%c%c%c%c%c\n",
	(flags & kSCNetworkReachabilityFlagsIsWWAN)				  ? 'W' : '-',
	(flags & kSCNetworkReachabilityFlagsReachable)            ? 'R' : '-',
			
	(flags & kSCNetworkReachabilityFlagsTransientConnection)  ? 't' : '-',
	(flags & kSCNetworkReachabilityFlagsConnectionRequired)   ? 'c' : '-',
	(flags & kSCNetworkReachabilityFlagsConnectionOnTraffic)  ? 'C' : '-',
	(flags & kSCNetworkReachabilityFlagsInterventionRequired) ? 'i' : '-',
	(flags & kSCNetworkReachabilityFlagsConnectionOnDemand)   ? 'D' : '-',
	(flags & kSCNetworkReachabilityFlagsIsLocalAddress)       ? 'l' : '-',
	(flags & kSCNetworkReachabilityFlagsIsDirect)             ? 'd' : '-'
	);
}

-(void)reachabilityChanged:(SCNetworkReachabilityFlags)newState {

  PrintReachabilityFlags(newState);

  SpdyNetworkStatus newStatus = [SPDY networkStatusForReachabilityFlags:newState];
  SpdyNetworkStatus oldStatus = networkStatus;

  SPDY_LOG(@"reachabilityChanged: old %d new %d", oldStatus, newStatus);

  if(oldStatus == newStatus) {
    // reachability didn't actually change.
  } else if(newStatus == kSpdyNotReachable) {
    SPDY_LOG(@"we were reachable, but no longer are, disconnect");
    // we were reachable, but no longer are, disconnect
    networkStatus = newStatus;
    [self teardown];
  } else if(oldStatus == kSpdyNotReachable) {
    SPDY_LOG(@"were not reachable, now we are, reconnect");
    // were not reachable, now we are, reconnect
    networkStatus = newStatus;
    [self teardown];
    [self reconnect:nil];
  } else if(oldStatus == kSpdyReachableViaWiFi && 
	    newStatus == kSpdyReachableViaWWAN) {
    SPDY_LOG(@"was on wifi, now on wwan, reconnect");
    // was on wifi, now on wwan, reconnect
    networkStatus = newStatus;
    [self teardown];
    [self reconnect:nil];
  } else if(oldStatus == kSpdyReachableViaWWAN && 
	    newStatus == kSpdyReachableViaWiFi) {
    SPDY_LOG(@"not switching away from 3g in the presence of a wifi network");
    // in this case we explicitly don't set our network status to 
    // the new status because we are still relying upon the old status (3g)

    // XXX make sure that 3g is still valid here (send ping??)
  } else {
    SPDY_LOG(@"ignoring reachability state change: (%d => %d)", oldStatus, newStatus);
  }
      
  // XXX ignored here is the case where we were on wwan, and are now on wifi,
  // but WWAN is no longer available.  In this case, we really should switch 
  // to WIFI.  (not sure how to dectect reliably).
}

static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info)
{
#pragma unused (target, flags)
  NSCAssert(info != NULL, @"info was NULL in ReachabilityCallback");
  NSCAssert([(__bridge NSObject*) info isKindOfClass: [SpdyPersistentUrl class]], @"info was wrong class in ReachabilityCallback");

  //We're on the main RunLoop, so an NSAutoreleasePool is not necessary, but is added defensively
  // in case someon uses the Reachablity object in a different thread.
  @autoreleasepool {
	
    SpdyPersistentUrl* self = (__bridge SpdyPersistentUrl*) info;
    [self reachabilityChanged:flags];
    // Post a notification to notify the client that the network reachability changed.
    //[[NSNotificationCenter defaultCenter] postNotificationName: kReachabilityChangedNotification object: noteObject];
	
  }
}

- (BOOL) startNotifier {
  SPDY_LOG(@"host is %s", [self.URL.host UTF8String]);
  reachabilityRef = SCNetworkReachabilityCreateWithName(NULL, [self.URL.host UTF8String]);

  SCNetworkReachabilityFlags flags = 0;
  if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
    networkStatus = [SPDY networkStatusForReachabilityFlags:flags];
  }

  BOOL retVal = NO;
  SCNetworkReachabilityContext	context = {0, (__bridge void *)(self), NULL, NULL, NULL};
  SPDY_LOG(@"reachabilityRef %p", reachabilityRef);
  if(SCNetworkReachabilitySetCallback(reachabilityRef, ReachabilityCallback, &context)) {
    if(SCNetworkReachabilityScheduleWithRunLoop(reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)) {
      retVal = YES;
    }
  }
  return retVal;
}

- (void) stopNotifier {
  if(reachabilityRef != NULL) {
    SCNetworkReachabilityUnscheduleFromRunLoop(reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(reachabilityRef);
  }
}

-(void)reconnect:(NSError*)error {
  SPDY_LOG(@"reconnect:%@", error);

  // XXX make sure this is not a fatal error (e.g. host down, etc).
  if(error != nil) {
    if([error.domain isEqualToString:kSpdyErrorDomain]) {
      if(error.code == kSpdyRequestCancelled) {
	// in this case, we want to suppress the error
	// this is because on fatal errors we call
	// [SpdyStream cancelStream] which sends us this (also fatal) error
	// if we don't ignore it here, we will loop.
	return;
      } else if(error.code == kSpdyConnectionFailed ||
		error.code == kSpdyConnectionNotSpdy ||
		error.code == kSpdyInvalidResponseHeaders ||
		error.code == kSpdyHttpSchemeNotSupported ||
		error.code == kSpdyStreamClosedWithNoRepsonseHeaders ||
		error.code == kSpdyVoipRequestedButFailed) {
	// call fatal error callback
	if(self.fatalErrorCallback != nil) {
	  self.fatalErrorCallback(error);
	}
	[self teardown];
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
	[self teardown];
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
	[self teardown];
	return;
      }

    }

    // XXX add more cases here
  }
  SPDY_LOG(@"error is not fatal");

  // here we do reconnect logic
  SpdyConnectState connectState = self.connectState;
  if(self.networkStatus == kSpdyNotReachable) {
    SPDY_LOG(@"not reachable");
    return;			// no point in connecting
  }

  if(!stream_closed && connectState == kSpdyConnected) {
    SPDY_LOG(@"already connected");
    return;			// already connected;
  }

  if(connectState == kSpdyConnecting || connectState == kSpdySslHandshake) {
    SPDY_LOG(@"already connecting, sending data anyways");
    //return;			// may want to set a timeout for lingering connects
  }

  SPDY_LOG(@"doing reconnect");
  // we are reachable, and not connected, and the error is not fatal, reconnect
  [self send];
}

-(void)keepalive {
  if(!stream_closed && self.connectState == kSpdyConnected) {
    pingTimer = [NSTimer timerWithTimeInterval:6 // XXX fudge this interval?
			 target:self selector:@selector(noPingReceived) 
			 userInfo:nil repeats:NO];
    [self sendPing];
  } else {
    [self teardown];
    [self reconnect:nil];
  }
}

-(void)streamWasConnected {
  // notice our reachability status, assume that this is how we are connected.

  SCNetworkReachabilityFlags flags = 0;
  if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
    networkStatus = [SPDY networkStatusForReachabilityFlags:flags];
  }
}

-(void)streamWasClosed {
  stream_closed = YES;
  [self reconnect:nil];
}

-(void)gotPing {
  [pingTimer invalidate];
  pingTimer = nil;
  if(self.keepAliveCallback != nil)
    self.keepAliveCallback();
}

-(void)noPingReceived {
  [pingTimer invalidate];
  pingTimer = nil;
  [self teardown];
  [self reconnect:nil];
}

-(void)dealloc {
  [self clearKeepAlive];
  [self stopNotifier];
}

- (id)initWithGETString:(NSString *)url {
  self = [super initWithGETString:url];
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
    self.connectCallback = ^ {
      [unsafe_self streamWasConnected];
    };
    [self startNotifier];
  }
  return self;
}

-(void)startKeepAliveWithTimeout:(NSTimeInterval)interval {
  [[UIApplication sharedApplication] setKeepAliveTimeout:interval handler:^{
    [self keepalive];
  }];
}

-(void)clearKeepAlive {
  [[UIApplication sharedApplication] clearKeepAliveTimeout];
}

@end
