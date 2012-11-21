
#import <Foundation/Foundation.h>

#import "SpdyUrl.h"

@interface SpdyPersistentUrl : SpdyUrl 
- (id)initWithUrlString:(NSString *)url;

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
