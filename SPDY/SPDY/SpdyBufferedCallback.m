#import "SpdyBufferedCallback.h"
#import "SpdyPushCallback.h"

@interface SpdyBufferedCallback ()

@property (nonatomic, assign) CFHTTPMessageRef headers;
@property (nonatomic, assign) CFMutableDataRef body;

@end

@implementation SpdyBufferedCallback {
  NSMutableSet * push_callbacks;
}

@synthesize url = _url;
@synthesize headers = _headers;
@synthesize body = _body;

- (id)init {
  self = [super init];
  if(self) {
    self.url = nil;
    _headers = NULL;
    self.body = NULL;
  }
  return self;
}

-(void)addPushCallback:(SpdyPushCallback*)callback {
  // this is all to make sure the push callbacks get retained
  if(push_callbacks == nil) {
    push_callbacks = [[NSMutableSet alloc] init];
  }
  [push_callbacks addObject:callback];
}

- (void)dealloc {
  CFRelease(_body);
  CFRelease(_headers);
}

- (void)setHeaders:(CFHTTPMessageRef)h {
  CFHTTPMessageRef oldRef = _headers;
  _headers = CFHTTPMessageCreateCopy(NULL, h);
  if (oldRef)
    CFRelease(oldRef);
}

- (void)onConnect:(id<SpdyRequestIdentifier>)u {
  self.url = u.url;
}

-(void)onResponseHeaders:(CFHTTPMessageRef)h {
  self.headers = h;
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
  if(self.body == NULL) 
    self.body = CFDataCreateMutable(NULL, 0);

  CFDataAppendBytes(self.body, bytes, length);
  //SPDY_LOG(@"appended %zd bytes", length);

  //SPDY_LOG(@"headers are %p", self.headers);
  
  if(self.headers == NULL) {
    SPDY_LOG(@"headers are null");
  } else {
    NSString* length_str = (NSString*)CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(self.headers, CFStringCreateWithCString(NULL,"content-length",kCFStringEncodingUTF8)));
    if(length_str != nil) {
      int content_length = 0;
      sscanf([length_str UTF8String], "%d", &content_length);
      SPDY_LOG(@"got content length %d", content_length);

      CFIndex current_data_size = CFDataGetLength(self.body);
      if(current_data_size == content_length) {
	//SPDY_LOG(@"got all the data, doing response callback before stream close");
	CFHTTPMessageSetBody(self.headers, self.body);
	[self onResponse:self.headers];
        self.body = NULL;
      }
    } else {
      //SPDY_LOG(@"did not get content-length");
      //SPDY_LOG(@"headers: %@", (NSDictionary*)CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(self.headers)));
    }
  }
  return length;
}

- (void)onStreamClose {
  SPDY_LOG(@"onStreamClose headers %@ body %@", self.headers, self.body);
  if(self.headers != NULL && self.body != NULL) {
    SPDY_LOG(@"doing response callback");
    CFHTTPMessageSetBody(self.headers, self.body);
    [self onResponse:self.headers];
  } else {
    SPDY_LOG(@"stream closing in error state: self.headers are %p, self.body %p", self.headers, self.body);
    NSDictionary * dict = [[NSDictionary alloc] 
                            initWithObjectsAndKeys:
                              @"stream closing in error state", @"reason",
                            (NSData*)self.body, @"data", nil];
    NSError * error = [[NSError alloc ] initWithDomain:kSpdyErrorDomain
                                        code:kSpdyStreamClosedWithNoRepsonseHeaders
                                        userInfo:dict];
    [self onError:error];
  }
}

- (void)onResponse:(CFHTTPMessageRef)response {
    
}

- (void)onError:(NSError *)error {
    
}

- (void)onPushResponse:(CFHTTPMessageRef)response withStreamId:(int32_t)streamId {
  
}

- (void)onPushError:(NSError *)error {

}
@end

