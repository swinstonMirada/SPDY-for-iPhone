#import "SpdyRequest.h"

@interface SpdyRequest (Private)
-(void)doSpdyPushCallbackWithMessage:(CFHTTPMessageRef)message andStreamId:(int32_t)streamId;
-(void)doSuccessCallbackWithMessage:(CFHTTPMessageRef)message;
-(void)doStreamCloseCallback;
@end
@interface NSDictionary (SpdyNetworkAdditions)
+ (id)dictionaryWithString:(NSString *)string separator:(NSString *)separator delimiter:(NSString *)delimiter;

- (id)objectForCaseInsensitiveKey:(NSString *)key;

@end
