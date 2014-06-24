#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

@interface SpdyDnsResult : NSObject
-(id)initWithAddrinfo:(struct addrinfo*)addrinfo;
-(id)initWithError:(NSError*)error;

@property (nonatomic, readonly) struct addrinfo* addrinfo;
@property (nonatomic, readonly, strong) NSError* error;
@end
