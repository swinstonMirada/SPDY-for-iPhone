#import "SpdyRequest.h"

@interface SpdyRequestCallback : BufferedCallback {
  SpdyRequest *spdy_url;
}

- (id)init:(SpdyRequest *) spdy_url;

@end
