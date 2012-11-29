#import "SpdyCallback.h"
#import "SPDY.h"

@implementation SpdyCallback

- (void)onRequestBytesSent:(NSInteger)bytesSend {
    
}

- (size_t)onResponseData:(const uint8_t *)bytes length:(size_t)length {
    return length;
}

- (void)onResponseHeaders:(CFHTTPMessageRef)headers {
}

- (void)onError:(NSError *)error {
    
}

- (void)onNotSpdyError:(id<SpdyRequestIdentifier>)identifier {
    
}

- (void)onStreamClose {
    
}

- (void)onConnect:(id<SpdyRequestIdentifier>)url {
    
}
@end
