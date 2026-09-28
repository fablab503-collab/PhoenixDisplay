#import "PhoenixVD.h"
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t w = argc > 1 ? atoi(argv[1]) : 5120;
        uint32_t h = argc > 2 ? atoi(argv[2]) : 2880;
        PhoenixVD *vd = [[PhoenixVD alloc] initWithName:@"settle" width:w height:h
                                            refreshRate:60 hiDPI:YES
                                               position:PhoenixVDPositionRight];
        if (!vd.active) { printf("FAILED: %s\n", vd.failureReason.UTF8String ?: "?"); return 1; }
        CGDirectDisplayID d = vd.displayID;
        printf("  asked %ux%u, watching what it settles to:\n", w, h);
        for (int i = 0; i < 2; i++) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
            printf("    t+%ds  %4zux%-4zu  mirrored=%d\n", i + 1,
                   CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d),
                   CGDisplayIsInMirrorSet(d));
        }
        // What modes does the system think this display has?
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
        if (modes) {
            printf("  available modes: %ld\n", CFArrayGetCount(modes));
            for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                printf("    %4zux%-4zu  (backing %4zux%-4zu)\n",
                       CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
                       CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m));
            }
            CFRelease(modes);
        }
        return 0;
    }
}
