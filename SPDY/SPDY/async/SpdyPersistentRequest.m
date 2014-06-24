#import "SpdyPersistentRequest.h"
#import "SpdyRequest+Private.h"
#import <SystemConfiguration/SystemConfiguration.h>
#if TARGET_OS_IPHONE
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>
#endif
#import <errno.h>
#import <netdb.h>
#import "SpdyTimer.h"

#define DEFAULT_INITIAL_RETRY_INTERVAL 0.2
#define DEFAULT_MAX_RETRY_INTERVAL 300
#define DEFAULT_RETRY_EXPONENT 0.2

static NSDictionary * radioAccessMap = nil;

@implementation SpdyPersistentRequest {
  SpdyTimer * pingTimer;
  SpdyTimer * retryTimer;
  BOOL stream_is_invalid;
  SCNetworkReachabilityRef reachabilityRef;
  SCNetworkReachabilityFlags currentReachability;
  SpdyRadioAccessTechnology radioAccessTechnology;
  int num_reconnects;
  NSDictionary * errorDict;
  id radioAccessObserver;

#if TARGET_OS_IPHONE
#else
  NSTimer * keepaliveTimer;
#endif
}

#if TARGET_OS_IPHONE
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
#else
static NSString * reachabilityString(SCNetworkReachabilityFlags    flags) {
  return
    [NSString stringWithFormat:@"%c %c%c%c%c%c%c%c\n",
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
#endif

+(NSString*)reachabilityString:(SCNetworkReachabilityFlags)flags {
  return reachabilityString(flags);
}

static void PrintReachabilityFlags(SCNetworkReachabilityFlags flags) {
  SPDY_LOG(@"Reachability Flag Status: %@", reachabilityString(flags));
}

-(void)reachabilityChanged:(SCNetworkReachabilityFlags)newState {

  SpdyNetworkStatus newStatus = [SPDY networkStatusForReachabilityFlags:newState];

  SpdyNetworkStatus oldStatus = [SPDY networkStatusForReachabilityFlags:currentReachability];

  currentReachability = newState;

  if(self.reachabilityCallback != NULL) {
    __spdy_dispatchAsyncOnMainThread(^{
				       self.reachabilityCallback(newState);
				     });
  }

  PrintReachabilityFlags(newState);

  SPDY_LOG(@"reachabilityChanged: old %@ new %@", [SPDY networkStatusString:oldStatus], [SPDY networkStatusString:newStatus]);

  if(oldStatus == newStatus) {
    // reachability didn't actually change.
  } else if(newStatus == kSpdyNetworkStatusNotReachable) {
    SPDY_LOG(@"we were reachable, but no longer are, disconnect");
    // we were reachable, but no longer are, disconnect
    [super teardown];
    // XXX perhaps we should call a new callback, separate from 
    // but similar to the retryCallback().  We may want to allow 
    // users of the library to start a background task here.
  } else if(oldStatus == kSpdyNetworkStatusNotReachable) {
    SPDY_LOG(@"were not reachable, now we are");
    // reset state because the previous state is now irrelevant
    [self resetState];
    if(super.connectState == kSpdyConnectStateConnected) {
      SPDY_LOG(@"BUT we think we were already connected, sending ping");
      [self sendPing];
    } else {
      SPDY_LOG(@"were not reachable, now we are, reconnect");
      // were not reachable, now we are, reconnect
      [super teardown];
      [self scheduleRecoverableReconnect:@"NOW REACHABLE"];
    }
#if TARGET_OS_IPHONE
  } else if(oldStatus == kSpdyNetworkStatusReachableViaWiFi && 
	    newStatus == kSpdyNetworkStatusReachableViaWWAN) {

    // reset state because the previous state is now irrelevant
    [self resetState];

    SPDY_LOG(@"was on wifi, now on wwan, reconnect");
    // was on wifi, now on wwan, reconnect
    [super teardown];
    [self scheduleRecoverableReconnect:@"WIFI TURNED OFF"];
  } else if(oldStatus == kSpdyNetworkStatusReachableViaWWAN && 
	    newStatus == kSpdyNetworkStatusReachableViaWiFi) {

    SPDY_LOG(@"not switching away from 3g in the presence of a wifi network");
    // in this case we explicitly don't set our network status to 
    // the new status because we are still relying upon the old status (3g)

    // XXX make sure that 3g is still valid here (send ping??)
    SPDY_LOG(@"sending ping to validate 3g connection");
    [self sendPing];
#endif
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
  NSCAssert([(__bridge NSObject*) info isKindOfClass: [SpdyPersistentRequest class]], @"info was wrong class in ReachabilityCallback");

  //We're on the main RunLoop, so an NSAutoreleasePool is not necessary, but is added defensively
  // in case someone uses the Reachablity object in a different thread.
  @autoreleasepool {
	
    SpdyPersistentRequest* self = (__bridge SpdyPersistentRequest*) info;
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
    if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) 
      currentReachability = flags;

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

#if TARGET_OS_IPHONE
-(SpdyRadioAccessTechnology)radioAccessTechnology {
  return [self radioAccessTechnology:[[CTTelephonyNetworkInfo alloc] init].currentRadioAccessTechnology];
}

-(SpdyRadioAccessTechnology)radioAccessTechnology:(id)object {
  if(object == nil) 
    return SpdyRadioAccessTechnologyNone;
 
  NSNumber * ret = radioAccessMap[object];
  if(ret == nil) 
    return SpdyRadioAccessTechnologyUnknown;

  return [ret intValue];
}

-(SpdyRadioAccessTechnology)radioAccessTechnologyForNotification:(NSNotification*)notification {
  return [self radioAccessTechnology:notification.object];
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

	if(/*networkStatus == kSpdyNetworkStatusReachableViaWWAN && */
	   oldAccessType != newAccessType) {
	  SPDY_LOG(@"we got radio access change from %@ to %@, sending a ping", [SPDY radioAccessString:oldAccessType], [SPDY radioAccessString:newAccessType]);
	  [self sendPing];
          /*
	} else {
	  SPDY_LOG(@"we're NOT connected via wwan, and got radio access change from %@ to %@, NOT sending a ping", [SPDY radioAccessString:oldAccessType], [SPDY radioAccessString:newAccessType]);
          */
        }

	radioAccessTechnology = newAccessType;

        // reset state because the previous state is now irrelevant
        [self resetState];

	if(self.radioAccessCallback != NULL) {
	  __spdy_dispatchAsyncOnMainThread(^{
					     self.radioAccessCallback(radioAccessTechnology);
					   });
	}

      } else {
	SPDY_LOG(@"got unexpected notification %@", notification);
      }
    }];

  if(self.radioAccessCallback != NULL) {
    SpdyRadioAccessTechnology srat = [self radioAccessTechnology];
    __spdy_dispatchAsyncOnMainThread(^{
				       self.radioAccessCallback(srat);
				     });
  }
}

- (void) stopRadioAccessNotifier {
  if(radioAccessObserver != nil) 
    [[NSNotificationCenter defaultCenter] removeObserver:radioAccessObserver];
  radioAccessObserver = nil;
}
#endif

#define RECOVERABLE_FAILURE 1
#define TRANSIENT_FAILURE   2
#define HARD_FAILURE        3
#define INTERNAL_FAILURE    4
#define UNHANDLED_FAILURE   5

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

	/* we ignore these, they happen every time we call [super teardown] */
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

  if(_dontReconnect) { 
    SPDY_LOG(@"NOT reconnecting because dontReconnect is set");
    return;
  }
  SPDY_LOG(@"reconnecting on failure for the %dth time", num_reconnects);
  num_reconnects++;

  // here we do reconnect logic
  SpdyConnectState currentConnectionState = super.connectState;
  SpdyNetworkStatus currentNetworkStatus = [SPDY networkStatusForReachabilityFlags:currentReachability];
  SPDY_LOG(@"reconnect: connectState %@ network reachability status %@", [SPDY connectionStateString:currentConnectionState], [SPDY networkStatusString:currentNetworkStatus]);

  if(currentNetworkStatus == kSpdyNetworkStatusNotReachable) {
    SPDY_LOG(@"not reachable");
    return;			// no point in connecting
  }

  if(super.isConnecting) {
    SPDY_LOG(@"connecting already, not doing it again");
    return;
  }

  if(!stream_is_invalid && currentConnectionState == kSpdyConnectStateConnected) {
    SPDY_LOG(@"already connected, not reconnecting");
    return;			// already connected;
  }

  if(currentConnectionState == kSpdyConnectStateConnecting || 
     currentConnectionState == kSpdyConnectStateSslHandshake) {
    SPDY_LOG(@"already connecting, sending data anyways");
    //return;			// may want to set a timeout for lingering connects
  }

  SPDY_LOG(@"doing reconnect");
  // we are reachable, and not connected, and the error is not fatal, reconnect
  [super send];
}

-(int)errorType:(NSError*)error {
  SPDY_LOG(@"errorType domain %@ code %lu", error.domain, (unsigned long)error.code);
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
  [super teardown];
}

-(void)scheduleRecoverableReconnect:(NSString*)tag {
  [self scheduleReconnectWithInitialInterval:self.initialRetryInterval
        factor:self.retryExponent
        maximum:self.maxRetryInterval
        andBlock:^{ 
    SPDY_LOG(@"%@ retry", tag);
    [self recoverableReconnect];
  }];
}

-(void)transientReconnect {
  SPDY_LOG(@"transientReconnect");
  [self reconnect];
}

-(void)recoverableReconnect {
  SPDY_LOG(@"recoverableReconnect");
  [self reconnect];
}

-(void)scheduleReconnectWithInitialInterval:(NSTimeInterval)retry_interval
				     factor:(double)factor
                                    maximum:(NSTimeInterval)maximum
				   andBlock:(void(^)())block {
  // schedule reconnect in the future

  if([retryTimer isValid]) {
    SPDY_LOG(@"not scheduling retry when we already have one scheduled for %lf seconds from now", [retryTimer.fireDate timeIntervalSinceNow]);
    return;
  }

  [super clearConnectionStatus];

  SpdyNetworkStatus currentNetworkStatus = [SPDY networkStatusForReachabilityFlags:currentReachability];

  SPDY_LOG(@"scheduleReconnectWithInitialInterval:%lf factor:%lf num_reconnects %d network status %@", retry_interval, factor, num_reconnects, [SPDY networkStatusString:currentNetworkStatus]);

  if(currentNetworkStatus == kSpdyNetworkStatusNotReachable) {
    SPDY_LOG(@"NOT scheduling reconnect because the network is not reachable now");
    return;
  }

  // exponential backoff
  for(int i = 0 ; i <= num_reconnects ; i++) retry_interval *= factor;

  if(retry_interval > maximum) {
    SPDY_LOG(@"clamping retry interval to the maximum value of %lf seconds", retry_interval);
    retry_interval = maximum;
  }    

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

  if([super tearingDown]) {
    SPDY_LOG(@"IGNORING ERROR WHILE TEARING DOWN");
    return;
  }

  if(error != nil) {
    int error_type = [self errorType:error];
    switch(error_type) {

    case HARD_FAILURE:
      {
	SPDY_LOG(@"error type is HARD_FAILURE");
	[super teardown];
        [self scheduleRecoverableReconnect:@"HARD FAILURE"];
      }
      break;

      
    case UNHANDLED_FAILURE:
      // this is a red flag, these errors should be flagged explicitly
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      SPDY_LOG(@"UNHANDLED_FAILURE UNHANDLED_FAILURE UNHANDLED_FAILURE");
      
      {
	SPDY_LOG(@"error type is UNHANDLED_FAILURE");
	[super teardown];
        [self scheduleRecoverableReconnect:@"UNHANDLED FAILURE"];
      }
      break;

    case INTERNAL_FAILURE:
      SPDY_LOG(@"error type is INTERNAL_FAILURE");
      // in this case, we want to suppress the error
      // this is because on fatal errors we call
      // [SpdyStream cancelStream] which sends us kSpdyRequestCancelled
      // which if also marked fatal will cause a loop

      {
	// XXX this is not congruent with the comment above
	[super teardown];
        [self scheduleRecoverableReconnect:@"INTERNAL FAILURE"];
      }
      break;

    case RECOVERABLE_FAILURE:
      {
	SPDY_LOG(@"error type is RECOVERABLE_FAILURE");
	[super teardown];
        [self scheduleRecoverableReconnect:@"RECOVERABLE FAILURE"];
      }
      break;

    case TRANSIENT_FAILURE:
      {
	SPDY_LOG(@"error type is TRANSIENT_FAILURE");
	[super teardown];
        [self scheduleRecoverableReconnect:@"TRANSIENT FAILURE"];
      }
      break;
    }
  }
}

-(void)sendPing {
  SPDY_LOG(@"sendPing");
  if(!stream_is_invalid && super.connectState == kSpdyConnectStateConnected) {
    SPDY_LOG(@"really sending ping");
    [pingTimer invalidate];
    pingTimer = [[SpdyTimer alloc] initWithInterval:6 // XXX hardcoded
				   andBlock:^{
      SPDY_LOG(@"doh, we didn't get a ping response");
      [self noPingReceived];
    }];
    [pingTimer start];
    [super sendPing];
  } else if(super.isConnecting) {
    SPDY_LOG(@"tried to send a ping while we were connecting, not doing it");
  } else if(super.connectState == kSpdyConnectStateConnecting || 
            super.connectState == kSpdyConnectStateSslHandshake) {
    SPDY_LOG(@"tried to send a ping with connectState %@, not gonna do it", [SPDY connectionStateString:super.connectState]);
  } else if([SPDY networkStatusForReachabilityFlags:currentReachability] != kSpdyNetworkStatusNotReachable) {
    SPDY_LOG(@"resetting connecting and instead of sending a ping because stream_is_invalid %d or super.connectState %@ != %@", stream_is_invalid, [SPDY connectionStateString:super.connectState], [SPDY connectionStateString:kSpdyConnectStateConnected]);
    [super teardown];
    [self scheduleRecoverableReconnect:@"NOT SENDING PING"];
  } else {
    SPDY_LOG(@"not sending ping when the network is not reachable");
  }
}

-(void)keepalive {
  SPDY_LOG(@"keepalive with connect state %@", [SPDY connectionStateString:super.connectState]);
  if(super.connectState == kSpdyConnectStateConnected) {
    SPDY_LOG(@"we are connected, sending keepalive ping");
    [self sendPing];
  } else if([retryTimer isValid]) {
    SPDY_LOG(@"not connected, not sending keepalive ping and not scheduling a retry when we have a one already scheduled for %lf seconds from now", [retryTimer.fireDate timeIntervalSinceNow]);
    return;
  } else {
    SPDY_LOG(@"got keepalive with connect state %@ and we are not scheduled to retry", [SPDY connectionStateString:super.connectState]);
    SpdyNetworkStatus currentNetworkStatus = [SPDY networkStatusForReachabilityFlags:currentReachability];
    if(currentNetworkStatus == kSpdyNetworkStatusNotReachable) {
      SPDY_LOG(@"we are not reachable on keepalive, doing nothing");
    } else {
      SPDY_LOG(@"on keepalive, we are reachable, but not connected, and there is no retry scheduled.");
    }
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

  SPDY_LOG(@"stream was connected");

  [retryTimer invalidate];

  // reset state because the previous state is now irrelevant
  [self resetState];
}


#define DONT_CALL_ME(var,callbackType)                                  \
-(void)var:(callbackType)callback {                                     \
  [NSException raise:@"InvalidOperation"                                \
               format:@"cannot call %s on a SpdyPersistentRequest", #var];  \
}                                                                       \

DONT_CALL_ME(setStreamCloseCallback,SpdyVoidCallback);
DONT_CALL_ME(setConnectCallback,SpdyVoidCallback);
DONT_CALL_ME(setPingCallback,SpdyBoolCallback);
DONT_CALL_ME(setErrorCallback,SpdyErrorCallback);

-(void)streamWasClosed {
  SPDY_LOG(@"streamWasClosed");
  stream_is_invalid = YES;
  [self scheduleRecoverableReconnect:@"STREAM CLOSED"];
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
  
  // the stream wasn't really closed, but we use this flag anyways
  stream_is_invalid = YES;
  [super teardown];

  [self scheduleRecoverableReconnect:@"NO PING"];
}

-(void)dealloc {
  [self clearKeepAlive];
  [self stopReachabilityNotifier];
#if TARGET_OS_IPHONE
  [self stopRadioAccessNotifier];
#endif
}

-(void)resetState {
  num_reconnects = 0;
  stream_is_invalid = NO;
}

-(void)setup {
#if TARGET_OS_IPHONE
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
#endif
  [self resetState];
  super.voip = YES;
  SpdyPersistentRequest * __weak weak_self = self;
  super.errorCallback = ^(NSError * error) {
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
  super.pingCallback = ^(BOOL success) {
    if(success)
      [weak_self gotPing];
    else
      [weak_self noPingReceived];
  };
  super.streamCloseCallback = ^ {
    SPDY_LOG(@"streamCloseCallback");
    [weak_self streamWasClosed];
  };
  super.connectCallback = ^ {
    SPDY_LOG(@"connectCallback");
    [weak_self streamWasConnected];
  };

  self.initialRetryInterval = DEFAULT_INITIAL_RETRY_INTERVAL;
  self.maxRetryInterval = DEFAULT_MAX_RETRY_INTERVAL;
  self.retryExponent = DEFAULT_RETRY_EXPONENT;

  [self startReachabilityNotifier];
#if TARGET_OS_IPHONE
  [self startRadioAccessNotifier];
#endif
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
  SPDY_LOG(@"startKeepAliveWithTimeout:%lf", interval);
#if TARGET_OS_IPHONE
  [[UIApplication sharedApplication] setKeepAliveTimeout:interval handler:^{
    [self keepalive];
  }];
#else
  //  [SPDY sharedSPDY].needToStartBackgroundTaskBlock();

  keepaliveTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                            target:self
                            selector:@selector(keepalive) 
                            userInfo:nil
                            repeats:YES];
#endif
}

-(void)clearKeepAlive {
#if TARGET_OS_IPHONE
  [[UIApplication sharedApplication] clearKeepAliveTimeout];
#else
  [keepaliveTimer invalidate];
  keepaliveTimer = nil;
  //  [SPDY sharedSPDY].finishedWithBackgroundTaskBlock();
#endif
}

@end
