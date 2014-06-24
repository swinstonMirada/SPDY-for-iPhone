#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#import "SpdyDnsResult.h"

@interface SpdyDnsResolver : NSObject

+(SpdyDnsResult*)lookupURL:(NSURL*)url;
+(SpdyDnsResult*)lookupHost:(NSString*)host;
+(SpdyDnsResult*)lookupHost:(NSString*)host withPort:(NSUInteger)port;

@end
