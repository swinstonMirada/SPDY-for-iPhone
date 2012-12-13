#import <Foundation/Foundation.h>

@interface SpdyTimer : NSObject
-(id)initWithInterval:(NSTimeInterval)_interval andBlock:(void(^)())_block;
-(void)start;
-(void)invalidate;
@end
