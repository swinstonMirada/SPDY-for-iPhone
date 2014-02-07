#import "SpdyDnsResolver.h"
#import "SPDY.h"

#define HTTPS_SCHEME @"https"
#define HTTPS_PORT 443

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

+(SpdyDnsResult *)lookupURL:(NSURL*)url {
  NSUInteger port = HTTPS_PORT;
  if (url.port != nil) {
    port = [url.port unsignedIntValue];
  } else {
    NSString * scheme = [url scheme];
    if([scheme isEqualToString:HTTPS_SCHEME ]) {
      port = HTTPS_PORT;
      /* 
	 in theory, bare http could be supported.
	 in practice, we require tls / ssl / https.
      */	 
    } else {
      NSDictionary * dict = [NSDictionary 
			      dictionaryWithObjectsAndKeys:
				[[NSString alloc] 
				  initWithFormat:@"Scheme %@ not supported", scheme], 
			      @"reason", nil];
      return [[SpdyDnsResult alloc] 
               initWithError:[NSError errorWithDomain:kSpdyErrorDomain 
                                      code:kSpdyHttpSchemeNotSupported 
                                      userInfo:dict]];
    }
  }
  return [self lookupHost:url.host withPort:port];
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
