#import "SpdyRequest.h"
#import "SPDY.h"

@interface SpdyHTTPResponse : NSHTTPURLResponse;
- (id)initWithURL:(NSURL *)URL message:(CFHTTPMessageRef)message;
@end



