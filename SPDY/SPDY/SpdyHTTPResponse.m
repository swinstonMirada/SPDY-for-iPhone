#import "SpdyHTTPResponse.h"


@implementation SpdyHTTPResponse

@synthesize statusCode = _statusCode;
@synthesize allHeaderFields = _allHeaderFields;
@synthesize requestBytes = _requestBytes;
@synthesize streamId = _streamId;

// In iOS 4.3 and below CFHTTPMessage uppercases the first letter of each word in the http header key.  In iOS 5 and up the headers
// from CFHTTPMessage are case insenstive.  Thus all header objectForKeys must use Word-Word casing.
+ (SpdyHTTPResponse *)responseWithURL:(NSURL *)url andMessage:(CFHTTPMessageRef)headers {
  NSMutableDictionary *headersDict = [CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(headers)) mutableCopy];
    [headersDict setObject:@"YES" forKey:@"protocol-was: spdy"];
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    NSString *contentType = [headersDict objectForKey:@"Content-Type"];
    NSString *contentLength = [headersDict objectForKey:@"Content-Length"];
    NSNumber *length = [f numberFromString:contentLength];
    NSInteger statusCode = CFHTTPMessageGetResponseStatusCode(headers);

    SpdyHTTPResponse *response = [[SpdyHTTPResponse alloc] initWithURL:url MIMEType:contentType expectedContentLength:[length intValue] textEncodingName:nil];
    response.statusCode = statusCode;
    response.allHeaderFields = headersDict;
    return response;
}

+ (NSHTTPURLResponse *)responseWithURL:(NSURL *)url andMessage:(CFHTTPMessageRef)headers withRequestBytes:(NSInteger)requestBytesSent {
  NSMutableDictionary *headersDict = [CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(headers)) mutableCopy];
    [headersDict setObject:@"YES" forKey:@"protocol-was: spdy"];
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    NSString *contentType = [headersDict objectForKey:@"Content-Type"];
    NSString *contentLength = [headersDict objectForKey:@"Content-Length"];
    NSNumber *length = [f numberFromString:contentLength];
    NSInteger statusCode = CFHTTPMessageGetResponseStatusCode(headers);
    NSString *version = CFBridgingRelease(CFHTTPMessageCopyVersion(headers));

    if ([[NSHTTPURLResponse class] instancesRespondToSelector:@selector(initWithURL:statusCode:HTTPVersion:headerFields:)]) {
        return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:statusCode  HTTPVersion:version headerFields:headersDict];
    }

    SpdyHTTPResponse *response = [[SpdyHTTPResponse alloc] initWithURL:url MIMEType:contentType expectedContentLength:[length intValue] textEncodingName:nil];
    response.statusCode = statusCode;
    response.allHeaderFields = headersDict;
    response.requestBytes = requestBytesSent;
    return response;
}

@end
