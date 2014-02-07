#import "SpdyDnsResolver.h"
#import "SPDY.h"

#define HTTPS_SCHEME @"https"
#define HTTPS_PORT 443

#define CACHE_KEY(host,service)                                         \
    [[NSString alloc] initWithFormat:@"%s%s", host, service == nil ? "" : service]

@implementation SpdyDnsResolver

static NSMutableDictionary * cache = NULL;

+(void)addToCache:(SpdyDnsResult*)result forHost:(const char*)host andPort:(const char*)port {
  if(cache == NULL) 
    cache = [[NSMutableDictionary alloc] init];
  cache[CACHE_KEY(host,port)] = result;
}

+(SpdyDnsResult*)getFromCacheForHost:(const char*)host andPort:(const char*)port {
  return cache[CACHE_KEY(host,port)];
}

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
    SPDY_LOG(@"Error getting IP address for %s (%@)", host, error);

    SpdyDnsResult * cached = [self getFromCacheForHost:host andPort:service];
    if(cached != nil && cached.addrinfo != NULL) {
      SPDY_LOG(@"got cached result %@, using that instead of returning error", cached);
      return cached;
    } else {
      SPDY_LOG(@"upon DNS failure, we have no cached result, so we are passing back the error");
      return [[SpdyDnsResult alloc] initWithError:error];
    }
  } else {
    SPDY_LOG(@"%p got IP address for %s", self, host);
    SpdyDnsResult * ret = [[SpdyDnsResult alloc] initWithAddrinfo:res];
    [self addToCache:ret forHost:host andPort:service];
    return ret;
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
