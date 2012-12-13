#import <Foundation/Foundation.h>

dispatch_queue_t __spdy_dispatch_queue(void);
void __spdy_dispatchSync(void(^block)());
void __spdy_dispatchAsync(void(^block)());
void __spdy_dispatchSyncOnMainThread(void(^block)());
void __spdy_dispatchAsyncOnMainThread(void(^block)());

@interface SpdyRequest (Private)
-(void)doSpdyPushCallbackWithMessage:(CFHTTPMessageRef)message andStreamId:(int32_t)streamId;
-(void)doSuccessCallbackWithMessage:(CFHTTPMessageRef)message;
-(void)doStreamCloseCallback;
@end
@interface NSDictionary (SpdyNetworkAdditions)
+ (id)dictionaryWithString:(NSString *)string separator:(NSString *)separator delimiter:(NSString *)delimiter;

- (id)objectForCaseInsensitiveKey:(NSString *)key;


@end
