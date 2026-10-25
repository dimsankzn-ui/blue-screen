#import <AppKit/AppKit.h>
#import "../Sources/VirtualDisplay.h"
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        BSVirtualDisplay *display = [BSVirtualDisplay new];
        NSError *error;
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        unsigned int width = args.count > 1 ? args[1].intValue : 1920;
        unsigned int height = args.count > 2 ? args[2].intValue : 1080;
        double rate = args.count > 3 ? args[3].doubleValue : 60;
        unsigned int serial = args.count > 4 ? (unsigned int)args[4].longLongValue : 1;
        NSString *name = args.count > 5 ? args[5] : @"BlueScreen TV";
        if (![display startWithWidth:width height:height rate:rate serial:serial name:name error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("%u\n", display.displayID);
        fflush(stdout);
        // Closing the parent's pipe (including parent crash) ends this helper.
        // Process teardown reliably removes the virtual screen on this macOS.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char byte;
            while (read(STDIN_FILENO, &byte, 1) > 0) {}
            exit(0);
        });
        [[NSRunLoop currentRunLoop] run];
        [display stop];
    }
    return 0;
}
