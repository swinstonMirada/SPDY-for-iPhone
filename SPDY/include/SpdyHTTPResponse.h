#import "SPDY.h"

@interface SpdyHTTPResponse : NSHTTPURLResponse;

@property (assign) NSInteger statusCode;
@property (copy) NSDictionary *allHeaderFields;
@property (assign) NSInteger requestBytes;
@property (assign) int32_t streamId;

+ (SpdyHTTPResponse *)responseWithURL:(NSURL *)url andMessage:(CFHTTPMessageRef)headers;
+ (NSHTTPURLResponse *)responseWithURL:(NSURL *)url andMessage:(CFHTTPMessageRef)headers withRequestBytes:(NSInteger)requestBytesSent;

@end



