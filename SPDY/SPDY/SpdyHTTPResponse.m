#import "SpdyHTTPResponse.h"

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

@implementation SpdyHTTPResponse {
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
