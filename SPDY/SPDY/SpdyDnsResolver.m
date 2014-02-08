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

#define DATA_FROM_URL(url)                                              \
  [[NSData alloc] initWithContentsOfURL:[NSURL URLWithString:url]]

#define STRING_FROM_URL(url)                            \
  [[NSString alloc] initWithData:DATA_FROM_URL(url)     \
                    encoding:NSUTF8StringEncoding ]

#define CHECK_URL(url)                                                  \
  SPDY_LOG(@"content for url %@:\n%@", url, STRING_FROM_URL(url));      \

+(void)checkConnectivity {
  SPDY_LOG(@"checking connectivity..");
  CHECK_URL(@"http://ota.locationlabs.com");
  CHECK_URL(@"http://www.yahoo.com/mobile");
}

+(SpdyDnsResult *)lookup:(const char*)host port:(const char*)service {

#ifdef CONF_Debug
  /* this is for testing
  dispatch_async(dispatch_get_main_queue(), ^{[self checkConnectivity];});
  {
    SpdyDnsResult * cached = [self getFromCacheForHost:host andPort:service];
    if(cached != nil && cached.addrinfo != NULL) {
      SPDY_LOG(@"got cached result %@, using that", cached);
      return cached;
    }
  }
  */
#endif

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

#ifdef CONF_Debug
    dispatch_async(dispatch_get_main_queue(), ^{[self checkConnectivity];});
#endif

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
