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
        // Report BOTH: CGDisplayPixelsWide gives points, which is half the real
        // resolution on a Retina mode. The pixel count is what actually matters.
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
        size_t pxW = m ? CGDisplayModeGetPixelWidth(m) : 0;
        size_t pxH = m ? CGDisplayModeGetPixelHeight(m) : 0;
        if (m) CGDisplayModeRelease(m);
        printf("  asked %4ux%-4u hiDPI=%d -> %4zux%-4zu points, %4zux%-4zu PIXELS  mirrored=%d\n",
               w, h, hidpi, CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d),
               pxW, pxH, CGDisplayIsInMirrorSet(d));
        return 0;
    }
}
