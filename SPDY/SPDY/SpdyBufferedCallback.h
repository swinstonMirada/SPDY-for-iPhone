#import "SpdyCallback.h"

@class SpdyPushCallback;

@interface SpdyBufferedCallback : SpdyCallback {
}

// Derived classses should override these methods since SpdyBufferedCallback overrides the rest of the callbacks from SpdyCallback.
- (void)onResponse:(CFHTTPMessageRef)response;
- (void)onPushResponse:(CFHTTPMessageRef)response withStreamId:(int32_t)streamId;
- (void)onError:(NSError *)error;
- (void)onPushError:(NSError *)error;

-(void)addPushCallback:(SpdyPushCallback*)callback;

@property (nonatomic, strong) NSURL *url;

@end

