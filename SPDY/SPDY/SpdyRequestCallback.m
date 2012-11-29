#import "SpdyRequestCallback.h"
#import "SpdyRequest+Private.h"

@implementation SpdyRequestCallback 

- (id)init:(SpdyRequest *) u {
  self = [super init];
  spdy_url = u;

  return self;
}

- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier {
  if(spdy_url.errorCallback != nil) {
    NSDictionary * dict = [[NSDictionary alloc] 
			    initWithObjectsAndKeys:
			      @"Host does not support SPDY", @"reason", nil];
    NSError * error = [[NSError alloc ] initWithDomain:kSpdyErrorDomain
					code:kSpdyConnectionNotSpdy
					userInfo:dict];
    spdy_url.errorCallback(error);
  }
}

- (void)onError:(NSError *)error {
  SPDY_LOG(@"Got error: %@", error);
  if(spdy_url.errorCallback != nil) {
    spdy_url.errorCallback(error);
  } else {
    SPDY_LOG(@"dropping error %@ w/ no callback", error);
  }
}

- (void)onConnect:(id<SpdyRequestIdentifier>)u {
  [super onConnect:u];
  //SPDY_LOG(@"connected");
  spdy_url.URL = u.url;
  if(spdy_url.connectCallback != nil) {
    spdy_url.connectCallback();
  }
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
  //SPDY_LOG(@"Loading");
  return [super onResponseData:bytes length:length];
}

- (void)onStreamClose {
  [spdy_url doStreamCloseCallback];
}

- (void)onPushResponse:(CFHTTPMessageRef)response withStreamId:(int32_t)streamId {
  [spdy_url doPushCallbackWithMessage:response andStreamId:streamId];
}

- (void)onResponse:(CFHTTPMessageRef)response {
  [spdy_url doSuccessCallbackWithMessage:response];
}

@end
