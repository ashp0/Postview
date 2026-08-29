#import "PVAppDelegate.h"

// NSApplication does not retain its delegate, so this object has to outlive
// -run -- which never returns, because -terminate: exits the process. The
// delegate is therefore deliberately immortal. Held in a file-scope reference
// rather than a local so that is stated rather than implied, and so a reader
// (and the static analyser) can see the +1 is held on purpose and not dropped.
static PVAppDelegate *sDelegate;

int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        sDelegate = [[PVAppDelegate alloc] init];
        [NSApp setDelegate:sDelegate];
        [NSApp run];
    }
    return 0;
}
