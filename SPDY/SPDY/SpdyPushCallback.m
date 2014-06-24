#import "SpdyPushCallback.h"
#import "SpdyBufferedCallback.h"
#import "SPDY.h"

@implementation SpdyPushCallback {
  __unsafe_unretained SpdyBufferedCallback * parent;
  int32_t streamId;
}

-(id)initWithParentCallback:(SpdyBufferedCallback*)_parent andStreamId:(int32_t)_streamId {
  self = [super init];
  if(self) {
    parent = _parent;
    [parent addPushCallback:self];
    streamId = _streamId;
  }
  return self;
}

- (void)onResponse:(CFHTTPMessageRef)response {
  if(parent) [parent onPushResponse:response withStreamId:streamId];
}

- (void)onError:(NSError *)error {
  if(parent) [parent onPushError:error];
}
@end

