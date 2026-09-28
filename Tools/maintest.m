#import "PhoenixVD.h"
#import <CoreGraphics/CoreGraphics.h>

static void dump(const char *when) {
    CGDirectDisplayID onl[16]; uint32_t no = 0;
    CGGetOnlineDisplayList(16, onl, &no);
    printf("  %s\n", when);
    for (uint32_t i = 0; i < no; i++) {
        CGRect b = CGDisplayBounds(onl[i]);
        printf("     id=%-4u %4zux%-4zu origin=(%5.0f,%5.0f) builtin=%d MAIN=%d\n",
               onl[i], CGDisplayPixelsWide(onl[i]), CGDisplayPixelsHigh(onl[i]),
               b.origin.x, b.origin.y, CGDisplayIsBuiltin(onl[i]), CGDisplayIsMain(onl[i]));
    }
}

int main(void) {
    @autoreleasepool {
        dump("before");
        PhoenixVD *vd = [[PhoenixVD alloc] initWithName:@"Phoenix 5K"
                                                  width:5120 height:2880
                                            refreshRate:60 hiDPI:YES
                                               position:PhoenixVDPositionRight];
        printf("  created: active=%d id=%u\n", vd.active, vd.displayID);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        dump("virtual display created (to the right)");

        printf("  makeMainDisplay -> %d\n", [vd makeMainDisplay]);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        dump("after making it MAIN");

        printf("  restoreBuiltInAsMain -> %d\n", [PhoenixVD restoreBuiltInAsMain]);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        dump("after restoring the built-in");
        [vd invalidate];
        return 0;
    }
}
