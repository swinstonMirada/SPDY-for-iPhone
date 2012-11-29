#import "SpdyRequest.h"
#import "SPDY.h"

/* XXX this class should probably be combined with 
   SpdyRequestResponse (in SpdyUrlConnection.h) */

@interface SpdyHTTPResponse : NSHTTPURLResponse;
- (id)initWithURL:(NSURL *)URL message:(CFHTTPMessageRef)message;
@end



