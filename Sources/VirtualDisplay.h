#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
uint32_t BSSystemCanSleepMessage(void);
uint32_t BSSystemWillSleepMessage(void);
// Experimental runtime bridge. No driver or persistent system extension is installed.
@interface BSVirtualDisplay : NSObject
@property(readonly) uint32_t displayID;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)startWithWidth:(unsigned int)width height:(unsigned int)height rate:(double)rate serial:(unsigned int)serial name:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
