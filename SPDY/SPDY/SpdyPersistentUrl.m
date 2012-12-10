#import "SpdyPersistentUrl.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <netdb.h>

@implementation SpdyPersistentUrl {
  NSTimer * pingTimer;
  NSTimer * retryTimer;
  BOOL stream_closed;
  SCNetworkReachabilityRef reachabilityRef;
  SpdyNetworkStatus networkStatus;
  int num_reconnects;
  NSDictionary * errorDict;
}

-(void)setNetworkStatus:(SpdyNetworkStatus) _networkStatus {
  networkStatus = _networkStatus;
  if(self.networkStatusCallback != NULL)
    self.networkStatusCallback(networkStatus);
}

static NSString * reachabilityString(SCNetworkReachabilityFlags    flags) {
  return
    [NSString stringWithFormat:@"%c%c %c%c%c%c%c%c%c\n",
	      (flags & kSCNetworkReachabilityFlagsIsWWAN)               ? 'W' : '-',
	      (flags & kSCNetworkReachabilityFlagsReachable)            ? 'R' : '-',
	      (flags & kSCNetworkReachabilityFlagsTransientConnection)  ? 't' : '-',
	      (flags & kSCNetworkReachabilityFlagsConnectionRequired)   ? 'c' : '-',
	      (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic)  ? 'C' : '-',
	      (flags & kSCNetworkReachabilityFlagsInterventionRequired) ? 'i' : '-',
	      (flags & kSCNetworkReachabilityFlagsConnectionOnDemand)   ? 'D' : '-',
	      (flags & kSCNetworkReachabilityFlagsIsLocalAddress)       ? 'l' : '-',
	      (flags & kSCNetworkReachabilityFlagsIsDirect)             ? 'd' : '-'
     ];
}

+(NSString*)reachabilityString:(SCNetworkReachabilityFlags)flags {
  return reachabilityString(flags);
}

static void PrintReachabilityFlags(SCNetworkReachabilityFlags flags) {
  SPDY_LOG(@"Reachability Flag Status: %@", reachabilityString(flags));
}

-(void)reachabilityChanged:(SCNetworkReachabilityFlags)newState {

  if(self.reachabilityCallback != NULL) 
    self.reachabilityCallback(newState);

  PrintReachabilityFlags(newState);

  SpdyNetworkStatus newStatus = [SPDY networkStatusForReachabilityFlags:newState];

  SpdyNetworkStatus oldStatus = networkStatus;

  SPDY_LOG(@"reachabilityChanged: old %d new %d", oldStatus, newStatus);

  if(oldStatus == newStatus) {
    // reachability didn't actually change.
  } else if(newStatus == kSpdyNotReachable) {
    SPDY_LOG(@"we were reachable, but no longer are, disconnect");
    // we were reachable, but no longer are, disconnect
    [self setNetworkStatus:newStatus];
    [self teardown];
  } else if(oldStatus == kSpdyNotReachable) {
    SPDY_LOG(@"were not reachable, now we are");
    if(self.connectState == kSpdyConnected) {
      SPDY_LOG(@"BUT we think we were already connected, sending ping");
      [self sendPing];
    } else {
      SPDY_LOG(@"reconnect");
      // were not reachable, now we are, reconnect
      [self setNetworkStatus:newStatus];
      [self teardown];
      [self reconnect:nil];
    }
  } else if(oldStatus == kSpdyReachableViaWiFi && 
	    newStatus == kSpdyReachableViaWWAN) {
    SPDY_LOG(@"was on wifi, now on wwan, reconnect");
    // was on wifi, now on wwan, reconnect
    [self setNetworkStatus:newStatus];
    [self teardown];
    [self reconnect:nil];
  } else if(oldStatus == kSpdyReachableViaWWAN && 
	    newStatus == kSpdyReachableViaWiFi) {
    SPDY_LOG(@"not switching away from 3g in the presence of a wifi network");
    // in this case we explicitly don't set our network status to 
    // the new status because we are still relying upon the old status (3g)

    // XXX make sure that 3g is still valid here (send ping??)
    SPDY_LOG(@"sending ping to validate 3g connection");
    [self sendPing];
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
  const char * host = [self.URL.host UTF8String];
  SPDY_LOG(@"host is %s", host);
  if(host == NULL) {
    SPDY_LOG(@"host is null, unable to start reachability notifier");
    return NO;
  }

  reachabilityRef = SCNetworkReachabilityCreateWithName(NULL, host);

  SCNetworkReachabilityFlags flags = 0;
  if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
    [self setNetworkStatus:[SPDY networkStatusForReachabilityFlags:flags]];
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

#define RECOVERABLE_FAILURE 1
#define TRANSIENT_FAILURE   2
#define HARD_FAILURE        3
#define INTERNAL_FAILURE    4
#define UNHANDLED_FAILURE   5

#define MAX_RECOVERABLE_RECONNECTS 50
#define MAX_TRANSIENT_RECONNECTS 10

-(NSDictionary*)errorDict {
  // here we build an NSDictionary which maps from NSError objects
  // to one of the failure types above

  if(errorDict == nil) {
    errorDict = @{

      // these are errors from the spdy layer 
      kSpdyErrorDomain : @{ 
	/* the connection failed for some reason */
	@((int)kSpdyConnectionFailed) : @RECOVERABLE_FAILURE,

	/* the url does not support spdy */
	@((int)kSpdyConnectionNotSpdy) : @HARD_FAILURE,
	
	/* invalid data received for the response headers */
	@((int)kSpdyInvalidResponseHeaders) : @RECOVERABLE_FAILURE,

	/* url has something other than http or https */
	@((int)kSpdyHttpSchemeNotSupported) : @HARD_FAILURE,

	/* stream was closed with no data sent */
	@((int)kSpdyStreamClosedWithNoRepsonseHeaders) : @RECOVERABLE_FAILURE,

	/* we asked for voip, but didn't get it */
	@((int)kSpdyVoipRequestedButFailed) : @HARD_FAILURE,

	/* we ignore these, they happen every time we call [self teardown] */
	@((int)kSpdyRequestCancelled) : @INTERNAL_FAILURE,

	/* this happens when the ssl handshake loops on SSL_ERROR_WANT_READ */
	@((int)kSpdySslErrorWantReadLoop) : @HARD_FAILURE,
      },
      
      // these are bsd level errors
      NSPOSIXErrorDomain : @{ 
	/* connection refused */
	@ECONNREFUSED : @TRANSIENT_FAILURE,

	/* host is down */
	@EHOSTDOWN : @TRANSIENT_FAILURE,

	/* no route to host */
	@EHOSTUNREACH : @HARD_FAILURE,

	/* Protocol family not supported */
	@EPFNOSUPPORT : @HARD_FAILURE,

	/* Socket type not supported */
	@ESOCKTNOSUPPORT : @HARD_FAILURE,
	
	/* Operation not supported */
	@ENOTSUP : @HARD_FAILURE,

	/* Socket operation on non-socket */
	@ENOTSOCK : @HARD_FAILURE,

	/* Destination address required */
	@EDESTADDRREQ : @HARD_FAILURE,

	/* Message too long */
	@EMSGSIZE : @HARD_FAILURE,

	/* Protocol wrong type for socket */
	@EPROTOTYPE : @HARD_FAILURE,

	/* Protocol not available */
	@ENOPROTOOPT : @HARD_FAILURE,

	/* Network is down */
	@ENETDOWN : @TRANSIENT_FAILURE,

	/* Network is unreachable */
	@ENETUNREACH : @TRANSIENT_FAILURE,

	/* Network dropped connection on reset */
	@ENETRESET : @RECOVERABLE_FAILURE,

	/* Software caused connection abort */
	@ECONNABORTED : @RECOVERABLE_FAILURE,

	/* Connection reset by peer */
	@ECONNRESET : @TRANSIENT_FAILURE,

	/* No buffer space available */
	@ENOBUFS : @RECOVERABLE_FAILURE,

	/* Socket is already connected */
	@EISCONN : @INTERNAL_FAILURE,

	/* Socket is not connected */
	@ENOTCONN : @RECOVERABLE_FAILURE,

	/* Can't send after socket shutdown */
	@ESHUTDOWN : @RECOVERABLE_FAILURE,

	/* Operation timed out */
	@ETIMEDOUT : @RECOVERABLE_FAILURE,

	/* Broken pipe */
	@EPIPE : @RECOVERABLE_FAILURE,
      },
      
      @"kCFStreamErrorDomainNetDB" : @{
	/* Authoritative Answer Host not found */
	@HOST_NOT_FOUND : @HARD_FAILURE,

	/* Non recoverable errors, FORMERR,REFUSED,NOTIMP*/
	@NO_RECOVERY : @HARD_FAILURE,

	/* Valid name, no data record of requested type */
	@NO_DATA : @HARD_FAILURE,

	/* address family for hostname not supported */
	@EAI_ADDRFAMILY : @HARD_FAILURE,
	
	/* invalid value for ai_flags */
	@EAI_BADFLAGS : @HARD_FAILURE,

	/* non-recoverable failure in name resolution */
	@EAI_FAIL : @HARD_FAILURE,
	
	/* ai_family not supported */
	@EAI_FAMILY : @HARD_FAILURE,
	
	/* no address associated with hostname */
	@EAI_NODATA : @HARD_FAILURE,
	
	/* hostname nor servname provided, or not known */
	@EAI_NONAME : @HARD_FAILURE,

	/* servname not supported for ai_socktype */
	@EAI_SERVICE : @HARD_FAILURE,

	/* ai_socktype not supported */
	@EAI_SOCKTYPE : @HARD_FAILURE,

	/* system error returned in errno */
	@EAI_SYSTEM : @HARD_FAILURE,

	/* invalid value for hints */
	@EAI_BADHINTS : @HARD_FAILURE,

	/* resolved protocol is unknown */
	@EAI_PROTOCOL : @HARD_FAILURE,

	/* argument buffer overflow */
	@EAI_OVERFLOW : @HARD_FAILURE,
      },

      // XXX add more cases here
    };
  }
  return errorDict;
}

-(void)reconnect {
  // here we do reconnect logic
  SpdyConnectState connectState = self.connectState;
  if(self.networkStatus == kSpdyNotReachable) {
    SPDY_LOG(@"not reachable");
    return;			// no point in connecting
  }

  if(!stream_closed && connectState == kSpdyConnected) {
    SPDY_LOG(@"already connected, not reconnecting");
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

-(int)errorType:(NSError*)error {
  NSNumber * type = [self errorDict][error.domain][@(error.code)];
  if(type == nil) return UNHANDLED_FAILURE;
  return [type intValue];
}

-(void)dieOnError:(NSError*)error {
  if(self.fatalErrorCallback != nil) {
    self.fatalErrorCallback(error);
  }
  [self teardown];
}

-(void)reconnectWithMax:(int)max {
  if(num_reconnects < max) {
    num_reconnects++;
    SPDY_LOG(@"reconnecting on failure for the %dth time", num_reconnects);
    [self reconnect];
  } else {
    SPDY_LOG(@"NOT reconnecting on failure for the %dth time", num_reconnects);
  }
}

-(void)transientReconnect {
  SPDY_LOG(@"transientReconnect");
  [self reconnectWithMax:MAX_TRANSIENT_RECONNECTS];
}

-(void)recoverableReconnect {
  SPDY_LOG(@"recoverableReconnect");
  [self reconnectWithMax:MAX_RECOVERABLE_RECONNECTS];
}

-(void)scheduleReconnectWithSelector:(SEL)selector 
		     initialInterval:(NSTimeInterval)retry_interval
			   andFactor:(double)factor {
  // schedule reconnect in the future

  // exponential backoff
  for(int i = 0 ; i <= num_reconnects ; i++) retry_interval *= factor;

  SPDY_LOG(@"will retry with selector %@ in %lf seconds", 
	   NSStringFromSelector(selector), retry_interval);

  [retryTimer invalidate];
  retryTimer = [NSTimer scheduledTimerWithTimeInterval:retry_interval
			target:self selector:selector
			userInfo:nil repeats:NO];
}

-(void)reconnect:(NSError*)error {
  SPDY_LOG(@"reconnect:%@", error);

  if([self tearingDown]) {
    SPDY_LOG(@"IGNORING ERROR WHILE TEARING DOWN");
    return;
  }

  if(error != nil) {
    int error_type = [self errorType:error];
    switch(error_type) {

    case HARD_FAILURE:
      SPDY_LOG(@"error type is HARD_FAILURE");
      // No retry is attempted
      // call fatalErrorCallback block
      // teardown the session (socket)
      [self dieOnError:error];
      break;

      
    case UNHANDLED_FAILURE:
      // this is a red flag, these errors should be flagged explicitly
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      [self dieOnError:error];
      break;

    case INTERNAL_FAILURE:
      SPDY_LOG(@"error type is INTERNAL_FAILURE");
      // in this case, we want to suppress the error
      // this is because on fatal errors we call
      // [SpdyStream cancelStream] which sends us kSpdyRequestCancelled
      // which if also marked fatal will cause a loop
      break;

    case RECOVERABLE_FAILURE:
      SPDY_LOG(@"error type is RECOVERABLE_FAILURE");
      [self teardown];
      [self scheduleReconnectWithSelector:@selector(recoverableReconnect) 
	    initialInterval:0.2 andFactor:1.6];
      break;

    case TRANSIENT_FAILURE:
      SPDY_LOG(@"error type is TRANSIENT_FAILURE");
      [self teardown];
      [self scheduleReconnectWithSelector:@selector(transientReconnect) 
	    initialInterval:0.8 andFactor:1.7];
      break;
    }
  }
}

-(void)keepalive {
  if(!stream_closed && self.connectState == kSpdyConnected) {
    pingTimer = [NSTimer scheduledTimerWithTimeInterval:6 // XXX fudge this interval?
			 target:self selector:@selector(noPingReceived) 
			 userInfo:nil repeats:NO];
    [self sendPing];
  } else {
    [self teardown];
    [self reconnect:nil];
  }
}

-(SCNetworkReachabilityFlags)reachabilityFlags {
  SCNetworkReachabilityFlags flags = 0;
  if(SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
    return flags;
  }
  return -1;
}

-(void)streamWasConnected {
  // notice our reachability status, assume that this is how we are connected.

  SCNetworkReachabilityFlags flags = [self reachabilityFlags];
  if(flags != -1)
    [self setNetworkStatus:[SPDY networkStatusForReachabilityFlags:flags]];

  SPDY_LOG(@"stream was connected");

  [retryTimer invalidate];
  num_reconnects = 0;
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

-(void)setup {
  num_reconnects = 0;
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

- (id)initWithRequest:(NSURLRequest *)request {
  self = [super initWithRequest:request];
  if(self) {
    [self setup];
  }
  return self;
}

- (id)initWithGETString:(NSString *)url {
  self = [super initWithGETString:url];
  if(self) {
    [self setup];
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
