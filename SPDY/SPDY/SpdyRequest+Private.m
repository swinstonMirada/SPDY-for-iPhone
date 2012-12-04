#import "SpdyRequest+Private.h"
#import "SpdyHTTPResponse.h"

@implementation SpdyRequest (Private)

-(void)doStreamCloseCallback {
  if(self.streamCloseCallback != nil) {
    self.streamCloseCallback();
  }
}

-(void)doCallbackWithMessage:(CFHTTPMessageRef)message andStreamId:(int32_t)streamId andCompletion:(LLSpdySuccessCallback)callback {
  CFDataRef b = CFHTTPMessageCopyBody(message);
  NSData * body = (__bridge NSData *)b;
  CFRelease(b);
  SpdyHTTPResponse * spdy_message = [SpdyHTTPResponse responseWithURL:self.URL
						      andMessage:message];

  spdy_message.streamId = streamId;
  if(callback != nil) {
    callback(spdy_message, body);
  } else {
    SPDY_LOG(@"dropping response w/ nil callback");
  }
}

-(void)doSpdyPushCallbackWithMessage:(CFHTTPMessageRef)message andStreamId:(int32_t)streamId {
  [self doCallbackWithMessage:message 
	andStreamId:streamId 
	andCompletion:self.pushSuccessCallback];
}

-(void)doSuccessCallbackWithMessage:(CFHTTPMessageRef)message {
  [self doCallbackWithMessage:message 
	andStreamId:0		// XXX stream id only on push for now
	andCompletion:self.successCallback];
}

@end

