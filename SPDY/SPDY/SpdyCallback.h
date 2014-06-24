#import "SPDY.h"

@interface SpdyCallback : NSObject {
}

// Methods that implementors should override.
- (void)onConnect:(id<SpdyRequestIdentifier>)identifier;
- (void)onRequestBytesSent:(NSInteger)bytesSend;
- (void)onResponseHeaders:(CFHTTPMessageRef)headers;
- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length;
- (void)onStreamClose;
- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier;

- (void)onError:(NSError *)error;

@end
