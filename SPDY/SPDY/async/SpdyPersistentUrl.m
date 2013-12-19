#import "SpdyPersistentUrl.h"
#import "SpdyRequest+Private.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <netdb.h>
#import "SpdyTimer.h"

static NSDictionary * radioAccessMap = nil;

@implementation SpdyPersistentUrl {
  SpdyTimer * pingTimer;
  SpdyTimer * retryTimer;
  BOOL stream_closed;
  SCNetworkReachabilityRef reachabilityRef;
  SpdyNetworkStatus networkStatus;
  SpdyRadioAccessTechnology radioAccessTechnology;
  int num_reconnects;
  NSDictionary * errorDict;
  id radioAccessObserver;
}

-(void)setNetworkStatus:(SpdyNetworkStatus) _networkStatus {
  networkStatus = _networkStatus;
  if(self.networkStatusCallback != NULL) {
    __spdy_dispatchAsyncOnMainThread(^{
				       self.networkStatusCallback(networkStatus);
				     });
  }
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

  if(self.reachabilityCallback != NULL) {
    __spdy_dispatchAsyncOnMainThread(^{
				       self.reachabilityCallback(newState);
				     });
  }

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
    // XXX perhaps we should call a new callback, separate from 
    // but similar to the retryCallback().  We may want to allow 
    // users of the library to start a background task here.
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
      [self recoverableReconnect];
    }
  } else if(oldStatus == kSpdyReachableViaWiFi && 
	    newStatus == kSpdyReachableViaWWAN) {
    SPDY_LOG(@"was on wifi, now on wwan, reconnect");
    // was on wifi, now on wwan, reconnect
    [self setNetworkStatus:newStatus];
    [self teardown];
    [self recoverableReconnect];
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

- (BOOL) startReachabilityNotifier {
  __block BOOL retVal = NO;
  void (^block)() = ^{
    const char * host = [self.URL.host UTF8String];
    SPDY_LOG(@"host is %s", host);
    if(host == NULL) {
      SPDY_LOG(@"host is null, unable to start reachability notifier");
      retVal = NO;
      return;
    }

    reachabilityRef = SCNetworkReachabilityCreateWithName(NULL, host);

    SCNetworkReachabilityFlags flags = 0;
    if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
      [self setNetworkStatus:[SPDY networkStatusForReachabilityFlags:flags]];
    }

    SCNetworkReachabilityContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    SPDY_LOG(@"reachabilityRef %p", reachabilityRef);
    if(SCNetworkReachabilitySetCallback(reachabilityRef, ReachabilityCallback, &context)) {
      if(SCNetworkReachabilityScheduleWithRunLoop(reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)) {
	retVal = YES;
      }
    }
  };
  __spdy_dispatchSync(block);
  return retVal;
}

- (void) stopReachabilityNotifier {
  if(reachabilityRef != NULL) {
    void (^block)() = ^{
      SCNetworkReachabilityUnscheduleFromRunLoop(reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
      CFRelease(reachabilityRef);
    };
    __spdy_dispatchSync(block);
  }
}

-(SpdyRadioAccessTechnology)radioAccessTechnologyForNotification:(NSNotification*)notification {
  id object = notification.object;

  if(object == nil) 
    return SpdyRadioAccessTechnologyNone;
  
  NSNumber * ret = radioAccessMap[object];
  if(ret == nil) 
    return SpdyRadioAccessTechnologyUnknown;

  return [ret intValue];
}

- (void) startRadioAccessNotifier {
  radioAccessObserver = 
    [[NSNotificationCenter defaultCenter] 
      addObserverForName:CTRadioAccessTechnologyDidChangeNotification
      object:nil queue:nil usingBlock:^(NSNotification*notification) {
      SPDY_LOG(@"got radio access change: %@", notification);
      if([notification.name isEqualToString:CTRadioAccessTechnologyDidChangeNotification]) {
	SpdyRadioAccessTechnology newAccessType = [self radioAccessTechnologyForNotification:notification];
	SpdyRadioAccessTechnology oldAccessType = radioAccessTechnology;

	if(self.networkStatus == kSpdyReachableViaWWAN &&
	   oldAccessType != newAccessType) {
	  SPDY_LOG(@"we're connected via wwan, and got radio access change from %d to %d, sending a ping", oldAccessType, newAccessType);
	  [self sendPing];
	}

	radioAccessTechnology = newAccessType;
      } else {
	SPDY_LOG(@"got unexpected notification %@", notification);
      }
    }];
}

- (void) stopRadioAccessNotifier {
  if(radioAccessObserver != nil) 
    [[NSNotificationCenter defaultCenter] removeObserver:radioAccessObserver];
  radioAccessObserver = nil;
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
	@((int)kSpdyConnectTimeout) : @TRANSIENT_FAILURE,
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
    __spdy_dispatchAsyncOnMainThread(^{
				       self.fatalErrorCallback(error);
				     });
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

-(void)scheduleReconnectWithInitialInterval:(NSTimeInterval)retry_interval
				     factor:(double)factor
				   andBlock:(void(^)())block {
  // schedule reconnect in the future

  // exponential backoff
  for(int i = 0 ; i <= num_reconnects ; i++) retry_interval *= factor;

  SPDY_LOG(@"will retry in %lf seconds", retry_interval);

  [retryTimer invalidate];
  retryTimer = [[SpdyTimer alloc] initWithInterval:retry_interval
				  andBlock:block];
  [retryTimer start];
  if(self.retryCallback != NULL)
    self.retryCallback(retry_interval);
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
      {
	SPDY_LOG(@"error type is RECOVERABLE_FAILURE");
	[self teardown];
	[self scheduleReconnectWithInitialInterval:0.2
	      factor:1.6 andBlock:^{ 
	  SPDY_LOG(@"recoverableReconnect retry");
	  [self recoverableReconnect];
	}];
      }
      break;

    case TRANSIENT_FAILURE:
      {
	SPDY_LOG(@"error type is TRANSIENT_FAILURE");
	[self teardown];
	[self scheduleReconnectWithInitialInterval:0.8
	      factor:1.7 andBlock:^{ [self transientReconnect];}];
      }
      break;
    }
  }
}

-(void)sendPing {
  SPDY_LOG(@"sendPing");
  if(!stream_closed && self.connectState == kSpdyConnected) {
    SPDY_LOG(@"really sending ping");
    [pingTimer invalidate];
    pingTimer = [[SpdyTimer alloc] initWithInterval:6 // XXX hardcoded
				   andBlock:^{
      SPDY_LOG(@"doh, we didn't get a ping response");
      [self noPingReceived];
    }];
    [pingTimer start];
    [super sendPing];
  } else {
    SPDY_LOG(@"not sending a ping because stream_closed %d and self.connectState %d != %d", 
	     stream_closed, self.connectState, kSpdyConnected);
    [self teardown];
    [self recoverableReconnect];
  }
}

-(void)keepalive {
  SPDY_LOG(@"keepalive");
  [self sendPing];
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

  if(self.connectCallback != nil) 
    __spdy_dispatchAsyncOnMainThread(self.connectCallback);
}

-(void)streamWasClosed {
  SPDY_LOG(@"streamWasClosed");
  stream_closed = YES;
  [self recoverableReconnect];
}

-(void)gotPing {
  SPDY_LOG(@"gotPing");
  [pingTimer invalidate];
  pingTimer = nil;
  if(self.keepAliveCallback != nil) 
    __spdy_dispatchAsyncOnMainThread(self.keepAliveCallback);
}

-(void)noPingReceived {
  SPDY_LOG(@"did not get ping");
  [pingTimer invalidate];
  pingTimer = nil;
  [self teardown];
  [self recoverableReconnect];
}

-(void)dealloc {
  [self clearKeepAlive];
  [self stopReachabilityNotifier];
  [self stopRadioAccessNotifier];
}

-(void)setup {
  if(radioAccessMap == nil) {
    radioAccessMap = @{
      CTRadioAccessTechnologyGPRS : @(SpdyRadioAccessTechnologyGPRS),
      CTRadioAccessTechnologyEdge : @(SpdyRadioAccessTechnologyEdge),
      CTRadioAccessTechnologyWCDMA : @(SpdyRadioAccessTechnologyWCDMA),
      CTRadioAccessTechnologyHSDPA : @(SpdyRadioAccessTechnologyHSDPA),
      CTRadioAccessTechnologyHSUPA : @(SpdyRadioAccessTechnologyHSUPA),
      CTRadioAccessTechnologyCDMA1x : @(SpdyRadioAccessTechnologyCDMA1x),
      CTRadioAccessTechnologyCDMAEVDORev0 : @(SpdyRadioAccessTechnologyCDMAEVDORev0),
      CTRadioAccessTechnologyCDMAEVDORevA : @(SpdyRadioAccessTechnologyCDMAEVDORevA),
      CTRadioAccessTechnologyCDMAEVDORevB : @(SpdyRadioAccessTechnologyCDMAEVDORevB),
      CTRadioAccessTechnologyeHRPD : @(SpdyRadioAccessTechnologyeHRPD),
      CTRadioAccessTechnologyLTE : @(SpdyRadioAccessTechnologyLTE)
    };
  }
  num_reconnects = 0;
  self.voip = YES;
  stream_closed = NO;
  SpdyPersistentUrl * __weak weak_self = self;
  self.errorCallback = ^(NSError * error) {
    SPDY_LOG(@"errorCallback");
#ifdef CONF_Debug
    if(weak_self.debugErrorCallback != nil) {
      __spdy_dispatchAsyncOnMainThread(^{
					 weak_self.debugErrorCallback(error);
				       });
    }
#endif
    [weak_self reconnect:error];
  };
  self.pingCallback = ^ {
    [weak_self gotPing];
  };
  self.streamCloseCallback = ^ {
    SPDY_LOG(@"streamCloseCallback");
    [weak_self streamWasClosed];
  };
  self.connectCallback = ^ {
    [weak_self streamWasConnected];
  };
  [self startReachabilityNotifier];
  [self startRadioAccessNotifier];
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
