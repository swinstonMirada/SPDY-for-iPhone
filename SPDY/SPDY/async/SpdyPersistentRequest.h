#import <Foundation/Foundation.h>
#import "SpdyRequest.h"

/*
 * This class provides a high level interface to a spdy implementation of 
 * an ios 'voip' persistent socket.
 *
 * This class should not be used with servers / urls which do not have the following
 * semantics:
 *
 * - uses SPDY
 * - uses HTTP GET
 * - provides the content-length header
 * - leaves the stream open after the response has been sent
 *
 * In addition, the server should support push.  If a push is received,
 * the pushSuccessCallback (declared in SpdyUrl) will be invoked.
 *
 * This class handles keepalive and reconnect details.  It provides an 
 * errorCallback for the SpdyRequest superclass which will attempt to 
 * reconnect on non-fatal errors.  In the event of a fatal error, 
 * the fatalErrorCallback is instead invoked.  
 */

@interface SpdyPersistentRequest : SpdyRequest 

- (id)initWithGETString:(NSString *)url;

/* Keepalive is not enabled initially.  Use this method to start it.
   Keepalive uses the UIApplication keepAliveTimeout. */
-(void)startKeepAliveWithTimeout:(NSTimeInterval)interval;

/* Keepalive is enabled initially.  Send this message to stop it. */
- (void)clearKeepAlive;

/* called on only fatal errors.  Otherwise we try to reconnect */
@property (nonatomic, copy) SpdyErrorCallback fatalErrorCallback;

/* called on all errors.  for debugging */
@property (nonatomic, copy) SpdyErrorCallback debugErrorCallback;

/* called on retry.  In case a background task is needed, this is NOT 
   called on the main thread, unlike all the other callbacks. 
   It is called synchronously so that a background task may be allocated. */
@property (nonatomic, copy) SpdyTimeIntervalCallback retryCallback;

/* called on keepalive */
@property (nonatomic, copy) SpdyVoidCallback keepAliveCallback;

/* called on initial connection */
@property (nonatomic, copy) SpdyVoidCallback connectCallback;

@property (nonatomic, copy) SpdyReachabilityCallback reachabilityCallback;

@property (nonatomic, copy) SpdyRadioAccessTechnologyCallback radioAccessCallback;

@property (nonatomic, assign) BOOL dontReconnect;

@property (nonatomic, readonly) SpdyRadioAccessTechnology radioAccessTechnology;

+(NSString*)reachabilityString:(SCNetworkReachabilityFlags)flags;

-(SCNetworkReachabilityFlags)reachabilityFlags;

@end
