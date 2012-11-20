#import "SpdyUrl.h"
#import "SPDY.h"

@interface SpdyUrl (Private)
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
  SpdyUrl *spdy_url;
}

- (id)init:(SpdyUrl *) spdy_url;
@end

@implementation Callback {
    
}

- (id)init:(SpdyUrl *) u {
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

@implementation SpdyUrl (Private)

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

@implementation SpdyUrl {
  Callback * delegate;
}

-(SpdyNetworkStatus)networkStatus {
  return [[SPDY sharedSPDY] networkStatusForUrlString:self.urlString];
}

-(SpdyConnectState)connectState {
  return [[SPDY sharedSPDY] connectStateForUrlString:self.urlString];
}

- (void)sendPing {
  //SPDY_LOG(@"pinging");
  [[SPDY sharedSPDY] ping:self.urlString callback:self.pingCallback];
}

-(void)doGET {
  [[SPDY sharedSPDY] fetch:self.urlString delegate:delegate voip:_voip];
}

- (void)teardown {
  [[SPDY sharedSPDY] teardown:self.urlString];
}

- (id)initWithUrlString:(NSString *)urlString {
  self = [super init];
  if(self) {
    delegate = [[Callback alloc] init:self];
    self.urlString = urlString;
    //SPDY_LOG(@"connecting");
  }
  return self;
}

@end
