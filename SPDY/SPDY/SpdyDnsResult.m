#import "SpdyDnsResult.h"

@implementation SpdyDnsResult
-(id)initWithAddrinfo:(struct addrinfo*)addrinfo {
  self = [super init];
  if(self) {
    _addrinfo = addrinfo;
  }
  return self;
}

-(id)initWithError:(NSError*)error { 
  self = [super init];
  if(self) {
    _error = error;
  }
  return self;
}
-(void)dealloc {
  if(self.addrinfo != nil)
    freeaddrinfo(self.addrinfo);
}
@end
