#import "PhoenixVD.h"
#import <CoreGraphics/CoreGraphics.h>

static void dumpDisplays(const char *when) {
    CGDirectDisplayID act[16], onl[16]; uint32_t na = 0, no = 0;
    CGGetActiveDisplayList(16, act, &na);
    CGGetOnlineDisplayList(16, onl, &no);
    printf("  %s: %u active, %u online\n", when, na, no);
    for (uint32_t i = 0; i < no; i++) {
        CGDirectDisplayID d = onl[i];
        printf("     id=%u %zux%zu builtin=%d main=%d inMirrorSet=%d mirrors=%u\n",
               d, CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d),
               CGDisplayIsBuiltin(d), CGDisplayIsMain(d),
               CGDisplayIsInMirrorSet(d), CGDisplayMirrorsDisplay(d));
    }
}

int main(void) {
    @autoreleasepool {
        printf("isSupported: %s\n", PhoenixVD.isSupported ? "YES" : "NO");
        if (PhoenixVD.unavailableReason)
            printf("reason: %s\n", PhoenixVD.unavailableReason.UTF8String);
        dumpDisplays("before");

        PhoenixVD *vd = [[PhoenixVD alloc] initWithName:@"Phoenix Test"
                                                  width:2560 height:1440
                                            refreshRate:60 hiDPI:YES];
        printf("active: %s  displayID: %u\n", vd.active ? "YES" : "NO", vd.displayID);
        if (vd.failureReason) printf("failure: %s\n", vd.failureReason.UTF8String);

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
        dumpDisplays("with virtual display");

        [vd invalidate];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        dumpDisplays("after invalidate");
        return 0;
    }
}
