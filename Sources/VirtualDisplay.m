#import "VirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>

// Non-public CoreGraphics API, also used by Chromium's virtual display tests:
// https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
// Resolve classes at runtime so removal of this API produces an error, not a launch failure.
@interface BSDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) dispatch_queue_t queue;
@end
@interface BSMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface BSSettings : NSObject
@property(strong) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface BSDisplay : NSObject
@property(readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

@implementation BSVirtualDisplay {
    BSDisplay *_screen;
}
- (uint32_t)displayID { return _screen ? _screen.displayID : 0; }
- (BOOL)startWithError:(NSError **)error {
    if (_screen) return YES;
    @autoreleasepool {
    @try {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
            @throw [NSException exceptionWithName:@"Unavailable" reason:@"Эта macOS не предоставляет экспериментальный виртуальный экран." userInfo:nil];
        }
        BSDescriptor *descriptor = [[descriptorClass alloc] init];
        descriptor.name = @"BlueScreen TV";
        descriptor.vendorID = 0x4253;
        descriptor.productID = 1;
        descriptor.serialNum = 1;
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = 1;
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.sizeInMillimeters = CGSizeMake(508.0, 285.75);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        BSDisplay *screen = [[displayClass alloc] initWithDescriptor:descriptor];
        BSSettings *settings = [[settingsClass alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[[[modeClass alloc] initWithWidth:1920 height:1080 refreshRate:60]];
        if (!screen || ![screen applySettings:settings] || screen.displayID == 0) {
            @throw [NSException exceptionWithName:@"CreationFailed" reason:@"macOS не создала виртуальный экран 1920 × 1080." userInfo:nil];
        }
        _screen = screen;
        return YES;
    } @catch (NSException *exception) {
        _screen = nil;
        if (error) *error = [NSError errorWithDomain:@"BlueScreen.VirtualDisplay" code:1
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Не удалось создать второй экран."}];
        return NO;
    }
    }
}
- (void)stop { _screen = nil; }
@end
