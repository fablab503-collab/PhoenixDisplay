#import "PhoenixVD.h"
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t w = argc > 1 ? atoi(argv[1]) : 2560;
        uint32_t h = argc > 2 ? atoi(argv[2]) : 1440;
        BOOL hidpi = argc > 3 ? atoi(argv[3]) : 1;
        PhoenixVD *vd = [[PhoenixVD alloc] initWithName:@"size probe" width:w height:h
                                            refreshRate:60 hiDPI:hidpi
                                               position:PhoenixVDPositionRight];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.2, false);
        if (!vd.active) { printf("  asked %ux%u hiDPI=%d -> FAILED (%s)\n", w, h, hidpi,
                                 vd.failureReason.UTF8String ?: "?"); return 1; }
        CGDirectDisplayID d = vd.displayID;
        printf("  asked %4ux%-4u hiDPI=%d -> got %4zux%-4zu  mirrored=%d\n",
               w, h, hidpi, CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d),
               CGDisplayIsInMirrorSet(d));
        return 0;
    }
}
