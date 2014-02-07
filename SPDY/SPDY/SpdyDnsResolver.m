#import "SpdyDnsResolver.h"
#import "SPDY.h"

@implementation SpdyDnsResolver

+(SpdyDnsResult *)lookup:(const char*)host port:(const char*)service {
  struct addrinfo hints;                        
  memset(&hints, 0, sizeof(struct addrinfo));   
  hints.ai_family = AF_INET;                    
  hints.ai_socktype = SOCK_STREAM;              

  struct addrinfo *res;
  SPDY_LOG(@"%p Looking up hostname for %s", self, host);
  int err = getaddrinfo(host, service, &hints, &res);
  if (err != 0) {
    NSError *error;
    if (err == EAI_SYSTEM) {
      error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    } else {
      error = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:err userInfo:nil];
    }
    SPDY_LOG(@"%p Error getting IP address for %s (%@)", self, host, error);
    return [[SpdyDnsResult alloc] initWithError:error];
  } else {
    return [[SpdyDnsResult alloc] initWithAddrinfo:res];
  }
}

+(SpdyDnsResult *)lookupHost:(NSString*)host {
  return [self lookup:[host UTF8String] port:NULL];
}

+(SpdyDnsResult *)lookupHost:(NSString*)host withPort:(NSUInteger)port {
  char service[10];
  snprintf(service, sizeof(service), "%lu", (unsigned long)port);
  return [self lookup:[host UTF8String] port:service];
}

@end
