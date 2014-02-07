#import "SpdyTimer.h"
#import "SpdyRequest.h"
#import "SpdyRequest+Private.h"

@implementation SpdyTimer {
  void (^block)();
  BOOL valid;
  NSTimeInterval interval;
  NSDate * fireDate;
}
-(id)initWithInterval:(NSTimeInterval)_interval andBlock:(void(^)())_block {
  self = [super init];
  if(self) {
    block = _block;
    interval = _interval;
    valid = YES;
  }
  return self;
}
-(void)start {
  if(valid) {
    dispatch_time_t when = 
      dispatch_time(DISPATCH_TIME_NOW,
		    (int64_t)(interval*1000000000.0)); // nanosec
    dispatch_block_t execution_block = ^{
      if(valid) { 
	block(); 
	valid = NO;
      }
    };
    // this is for reference
    fireDate = [[NSDate alloc] initWithTimeIntervalSinceNow:interval];
    dispatch_after(when, __spdy_dispatch_queue(), execution_block);
  }
}
-(void)invalidate {
  valid = NO;
}
-(BOOL)isValid {
  return valid;
}
-(NSDate*)fireDate {
  return fireDate;
}
@end
