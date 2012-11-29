#import "SpdyRequest.h"

@interface SpdyRequestCallback : SpdyBufferedCallback {
  SpdyRequest *spdy_url;
}

- (id)init:(SpdyRequest *) spdy_url;

@end
