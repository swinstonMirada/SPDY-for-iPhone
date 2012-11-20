
#import <Foundation/Foundation.h>

#import "SpdyUrl.h"

@interface SpdyPersistentUrl : SpdyUrl 
- (id)initWithUrlString:(NSString *)url;

/* called on only fatal errors.  Otherwise we try to reconnect */
@property (nonatomic, copy) LLSpdyErrorCallback fatalErrorCallback;

@end
