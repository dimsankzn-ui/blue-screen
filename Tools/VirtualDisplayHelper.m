#import <AppKit/AppKit.h>
#import "../Sources/VirtualDisplay.h"
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        BSVirtualDisplay *display = [BSVirtualDisplay new];
        NSError *error;
        if (![display startWithError:&error]) {
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
