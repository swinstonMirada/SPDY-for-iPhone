#import "SpdyRequest.h"
#import "SpdyRequest+Private.h"
#import "SpdyHTTPResponse.h"

static dispatch_queue_t _dispatchQueue = NULL;

static char * dispatch_queue_key = "key";
static char * dispatch_queue_key_value = "spdy";

dispatch_queue_t __spdy_dispatch_queue() {
  if(_dispatchQueue == NULL) {
    _dispatchQueue = dispatch_queue_create("Spdy", NULL);
    dispatch_queue_set_specific(_dispatchQueue, dispatch_queue_key, 
				dispatch_queue_key_value, NULL);
#ifdef CONF_Debug
    __spdy_dispatchAsync(^{ [[NSThread currentThread] setName:@"Spdy"]; });
#endif    
  }
  return _dispatchQueue;
}

void __spdy_dispatchSync(void(^block)()) {
  dispatch_queue_t dispatchQueue = __spdy_dispatch_queue();
  char * value = dispatch_get_specific(dispatch_queue_key);
  if(value == dispatch_queue_key_value) {
    block();
  } else {
    dispatch_sync(dispatchQueue, block);
  }
}

void __spdy_dispatchAsync(void(^block)()) {
  dispatch_async(__spdy_dispatch_queue(), block);
}

void __spdy_dispatchSyncOnMainThread(void(^block)()) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

void __spdy_dispatchAsyncOnMainThread(void(^block)()) {
  dispatch_async(dispatch_get_main_queue(), block);
}

@implementation SpdyRequest (Private)

-(void)doConnectCallback {
  if(self.connectCallback != nil) {
    self.connectCallback();
  }
} 

-(void)doStreamCloseCallback {
  if(self.streamCloseCallback != nil) {
    self.streamCloseCallback();
  }
}

-(void)doCallbackWithMessage:(CFHTTPMessageRef)message andStreamId:(int32_t)streamId andCompletion:(SpdySuccessCallback)callback {
  CFDataRef b = CFHTTPMessageCopyBody(message);
  NSData * body = (__bridge NSData *)b;
  SpdyHTTPResponse * spdy_message = [SpdyHTTPResponse responseWithURL:self.URL
						      andMessage:message];

  spdy_message.streamId = streamId;
  if(callback != nil) {
    callback(spdy_message, body);
  } else {
    SPDY_LOG(@"dropping response w/ nil callback");
  }
  CFRelease(b);
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

