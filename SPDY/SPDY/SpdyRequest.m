#import "SpdyRequest.h"
#import "SPDY.h"

@interface SpdyRequest (Private)
-(void)doPushCallbackWithMessage:(CFHTTPMessageRef)message;
-(void)doSuccessCallbackWithMessage:(CFHTTPMessageRef)message;
-(void)doStreamCloseCallback;
@end
@interface NSDictionary (SpdyNetworkAdditions)
+ (id)dictionaryWithString:(NSString *)string separator:(NSString *)separator delimiter:(NSString *)delimiter;

- (id)objectForCaseInsensitiveKey:(NSString *)key;


@end

@implementation NSDictionary (SpdyNetworkAdditions)

+ (id)dictionaryWithString:(NSString *)string separator:(NSString *)separator delimiter:(NSString *)delimiter {
  NSArray *parameterPairs = [string componentsSeparatedByString:delimiter];
        
  NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithCapacity:[parameterPairs count]];
        
  for (NSString *currentPair in parameterPairs) {
    NSArray *pairComponents = [currentPair componentsSeparatedByString:separator];
                
    NSString *key = ([pairComponents count] >= 1 ? [pairComponents objectAtIndex:0] : nil);
    if (key == nil) continue;
                
    NSString *value = ([pairComponents count] >= 2 ? [pairComponents objectAtIndex:1] : [NSNull null]);
    [parameters setObject:value forKey:key];
  }
        
  return parameters;
}


- (id)objectForCaseInsensitiveKey:(NSString *)key {
#if NS_BLOCKS_AVAILABLE
  __block id object = nil;
        
  [self enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^ (id currentKey, id currentObject, BOOL *stop) {
    if ([key caseInsensitiveCompare:currentKey] != NSOrderedSame) return;
                
    object = currentObject;
    *stop = YES;
  }];
        
  return object;
#else
  for (NSString *currentKey in self) {
    if ([currentKey caseInsensitiveCompare:key] != NSOrderedSame) continue;
    return [self objectForKey:currentKey];
  }
        
  return nil;
#endif
}


@end

@interface _SpdyMessage : NSHTTPURLResponse;
- (id)initWithURL:(NSURL *)URL message:(CFHTTPMessageRef)message;
@end

@implementation _SpdyMessage {
  CFHTTPMessageRef _message;
}

- (id)initWithURL:(NSURL *)URL message:(CFHTTPMessageRef)message {
  NSString *MIMEType = nil; 
  NSString *textEncodingName = nil;

  NSString *contentType = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(message, (CFStringRef)@"content-type"/*AFHTTPMessageContentTypeHeader XXX */));
  if (contentType != nil) {
    NSRange parameterSeparator = [contentType rangeOfString:@";"];
    if (parameterSeparator.location == NSNotFound) {
      MIMEType = contentType;
    } else {
      MIMEType = [contentType substringToIndex:parameterSeparator.location];
                        
      NSMutableDictionary *contentTypeParameters = [NSMutableDictionary dictionaryWithString:[contentType substringFromIndex:(parameterSeparator.location + 1)] separator:@"=" delimiter:@";"];

      [contentTypeParameters enumerateKeysAndObjectsUsingBlock:^ (id key, id obj, BOOL *stop) {
	[contentTypeParameters removeObjectForKey:key];
                                
	key = [key mutableCopy];
	CFStringTrimWhitespace((CFMutableStringRef)key);
                                
	obj = [obj mutableCopy];
	CFStringTrimWhitespace((CFMutableStringRef)obj);
                                
	[contentTypeParameters setObject:obj forKey:key];
      }];
      textEncodingName = [contentTypeParameters objectForCaseInsensitiveKey:@"charset"];
                        
      if ([textEncodingName characterAtIndex:0] == '"' && [textEncodingName characterAtIndex:([textEncodingName length] - 1)] == '"') {
	textEncodingName = [textEncodingName substringWithRange:NSMakeRange(1, [textEncodingName length] - 2)];
      }
    }
  }
        
  NSString *contentLength = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(message, (CFStringRef)@"content-length"/*AFHTTPMessageContentLengthHeader XXX*/));
        
  self = [self initWithURL:URL MIMEType:MIMEType expectedContentLength:(contentLength != nil ? [contentLength integerValue] : -1) textEncodingName:textEncodingName];
  if (self == nil) return nil;
        
  _message = message;
  CFRetain(message);
        
  return self;
}

- (void)dealloc {
  CFRelease(_message);
        
  //[super dealloc];
}

- (NSInteger)statusCode {
  return CFHTTPMessageGetResponseStatusCode(_message);
}

- (NSDictionary *)allHeaderFields {
  return CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_message));
}

@end

@interface Callback : BufferedCallback {
  SpdyRequest *spdy_url;
}

- (id)init:(SpdyRequest *) spdy_url;
@end

@implementation Callback {
    
}

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

- (void)onPushResponse:(CFHTTPMessageRef)response {
  [spdy_url doPushCallbackWithMessage:response];
}

- (void)onResponse:(CFHTTPMessageRef)response {
  [spdy_url doSuccessCallbackWithMessage:response];
}

@end

@implementation SpdyRequest (Private)

-(void)doStreamCloseCallback {
  if(self.streamCloseCallback != nil) {
    self.streamCloseCallback();
  }
}

// XXX refactor the common parts of these two methods
-(void)doPushCallbackWithMessage:(CFHTTPMessageRef)message {
  CFDataRef b = CFHTTPMessageCopyBody(message);
  NSData * body = (__bridge NSData *)b;
  CFRelease(b);
  _SpdyMessage * spdy_message = [[_SpdyMessage alloc] initWithURL:self.URL
						      message:message];

  if(self.pushSuccessCallback != nil) {
    self.pushSuccessCallback(spdy_message, body);
  } else {
    SPDY_LOG(@"dropping response w/ nil callback");
  }
}

-(void)doSuccessCallbackWithMessage:(CFHTTPMessageRef)message {
  CFDataRef b = CFHTTPMessageCopyBody(message);
  NSData * body = (__bridge NSData *)b;
  CFRelease(b);
  _SpdyMessage * spdy_message = [[_SpdyMessage alloc] initWithURL:self.URL
						      message:message];

  if(self.successCallback != nil) {
    self.successCallback(spdy_message, body);
  } else {
    SPDY_LOG(@"dropping response w/ nil callback");
  }
}

@end

@implementation SpdyRequest {
  Callback * delegate;
  NSURLRequest *  ns_url_request;
  NSString * urlString;
}

-(NSString*)urlString {
  if(ns_url_request == nil) {
    return urlString;
  } else {
    return ns_url_request.URL.absoluteString;
  }
}

-(SpdyNetworkStatus)networkStatus {
  if(ns_url_request == nil) {
    return [[SPDY sharedSPDY] networkStatusForUrlString:urlString];
  } else {
    return [[SPDY sharedSPDY] networkStatusForRequest:ns_url_request];
  }
}

-(SpdyConnectState)connectState {
  if(ns_url_request == nil) {
    return [[SPDY sharedSPDY] connectStateForUrlString:urlString];
  } else {
    return [[SPDY sharedSPDY] connectStateForRequest:ns_url_request];
  }
}

- (void)sendPing {
  //SPDY_LOG(@"pinging");
  if(ns_url_request == nil) {
    [[SPDY sharedSPDY] pingUrlString:urlString callback:self.pingCallback];
  } else {
    [[SPDY sharedSPDY] pingRequest:ns_url_request callback:self.pingCallback];
  }
}

-(void)send {
  if(ns_url_request == nil) {
    [[SPDY sharedSPDY] fetch:urlString delegate:delegate voip:_voip];
  } else {
    [[SPDY sharedSPDY] fetchFromRequest:ns_url_request delegate:delegate voip:_voip];
  }
}

- (void)teardown {
  if(ns_url_request == nil) {
    [[SPDY sharedSPDY] teardown:urlString];
  } else {
    [[SPDY sharedSPDY] teardownForRequest:ns_url_request];
  }
}

- (id)initWithGETString:(NSString *)_urlString {
  self = [super init];
  if(self) {
    delegate = [[Callback alloc] init:self];
    urlString = _urlString;
    self.URL = [[NSURL alloc] initWithString:urlString];
  }
  return self;
}

- (id)initWithRequest:(NSURLRequest *)request {
  self = [super init];
  if(self) {
    delegate = [[Callback alloc] init:self];
    ns_url_request = request;
  }
  return self;
}

@end


