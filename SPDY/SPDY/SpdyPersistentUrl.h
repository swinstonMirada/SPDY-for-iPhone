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
 * the pushSuccessCallback (declared in SpduUrl) will be invoked.
 *
 * This class handles keepalive and reconnect details.  It provides an 
 * errorCallback for the SpdyRequest superclass which will attempt to 
 * reconnect on non-fatal errors.  In the event of a fatal error, 
 * the fatalErrorCallback is instead invoked.  
 */

@interface SpdyPersistentUrl : SpdyRequest 
- (id)initWithGETString:(NSString *)url;

/* Keepalive is enabled initially.  If it has been stopped, send this message 
   to start it again.  Keepalive uses the UIApplication keepAliveTimeout. */
-(void)setKeepAlive;

/* Keepalive is enabled initially.  Send this message to stop it. */
- (void)clearKeepAlive;

/* called on only fatal errors.  Otherwise we try to reconnect */
@property (nonatomic, copy) LLSpdyErrorCallback fatalErrorCallback;

/* called on keepalive */
@property (nonatomic, copy) LLSpdyVoidCallback keepAliveCallback;

@end
