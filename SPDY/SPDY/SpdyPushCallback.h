#import "SpdyBufferedCallback.h"

// this callback is created internally to cause existing SpdyBufferedCallback objects
// to get a second onResponse: in the case that a push occurs.
@interface SpdyPushCallback : SpdyBufferedCallback 

-(id)initWithParentCallback:(SpdyBufferedCallback*)_parent andStreamId:(int32_t)_streamIdd;


@end
