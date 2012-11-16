#import <Foundation/Foundation.h>

@class SpdyUrl;

typedef void (^LLSpdyPingCallback)();
typedef void (^LLSpdySuccessCallback)(NSHTTPURLResponse*,NSData*);
typedef void (^LLSpdyErrorCallback)(NSError*);

@interface SpdyUrl : NSObject

- (id)initWithUrl:(NSString *)url;

/* causes the url to be loaded */
- (void)fetch;

/* causes spdy to send a ping over the associated session, if connected */
- (void)sendPing;

/* causes sendPing to be called with the specified interval */
- (void)pingWithTimeInterval:(NSTimeInterval)interval;

/* causes repeated calls to sendPing that were caused by pingWithTimeInterval: to stop */
- (void)stopPinging;

/* the url being loaded, as a string */
@property (nonatomic, strong) NSString* urlString;

/* the url being loaded as an NSURL */
@property (nonatomic, strong) NSURL* URL;

/* the body of the response, as NSData */
@property (nonatomic, strong) NSData* body;

/* if set to YES, causes kCFStreamNetworkServiceType to be set to
   kCFStreamNetworkServiceTypeVoIP (for voip background mode) 
   This needs to be set before the message fetch is sent. */
@property (nonatomic, assign) BOOL voip;



/* Block Callbacks */

/* called on success of the original url fetch */
@property (nonatomic, copy) LLSpdySuccessCallback successCallback;

/* called on failure of the original url fetch */
@property (nonatomic, copy) LLSpdyErrorCallback errorCallback;

/* called in the event that a valid push is received */
@property (nonatomic, copy) LLSpdySuccessCallback pushSuccessCallback;

/* called in the event that a push error is received */
@property (nonatomic, copy) LLSpdyErrorCallback pushErrorCallback;

/* called when a ping response is received */
@property (nonatomic, copy) LLSpdyPingCallback pingCallback;

@end
