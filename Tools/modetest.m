#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Directly exercise CGVirtualDisplay to find which combination of
// maxPixels / mode size / hiDPI actually yields a 5120x2880 desktop.
static CGDirectDisplayID make(uint32_t maxW, uint32_t maxH,
                              uint32_t modeW, uint32_t modeH, uint32_t hidpi,
                              id *keep) {
    Class dc = NSClassFromString(@"CGVirtualDisplayDescriptor");
    id desc = [[dc alloc] init];
    ((void(*)(id,SEL,id))objc_msgSend)(desc, NSSelectorFromString(@"setName:"), @"probe");
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsWide:"), maxW);
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsHigh:"), maxH);
    ((void(*)(id,SEL,CGSize))objc_msgSend)(desc, NSSelectorFromString(@"setSizeInMillimeters:"),
                                           CGSizeMake(600, 340));
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setVendorID:"), 0x3456);
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setProductID:"), 0x1234);
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(desc, NSSelectorFromString(@"setSerialNumber:"), 1);
    ((void(*)(id,SEL,id))objc_msgSend)(desc, NSSelectorFromString(@"setQueue:"), dispatch_get_main_queue());

    Class vdc = NSClassFromString(@"CGVirtualDisplay");
    CFTypeRef a = ((CFTypeRef(*)(Class,SEL))objc_msgSend)(vdc, NSSelectorFromString(@"alloc"));
    id disp = CFBridgingRelease(((CFTypeRef(*)(CFTypeRef,SEL,id))objc_msgSend)
                 (a, NSSelectorFromString(@"initWithDescriptor:"), desc));
    if (!disp) return 0;

    Class mc = NSClassFromString(@"CGVirtualDisplayMode");
    CFTypeRef ma = ((CFTypeRef(*)(Class,SEL))objc_msgSend)(mc, NSSelectorFromString(@"alloc"));
    id mode = CFBridgingRelease(((CFTypeRef(*)(CFTypeRef,SEL,uint32_t,uint32_t,double))objc_msgSend)
                 (ma, NSSelectorFromString(@"initWithWidth:height:refreshRate:"), modeW, modeH, 60.0));

    Class sc = NSClassFromString(@"CGVirtualDisplaySettings");
    id settings = [[sc alloc] init];
    ((void(*)(id,SEL,id))objc_msgSend)(settings, NSSelectorFromString(@"setModes:"), @[mode]);
    ((void(*)(id,SEL,uint32_t))objc_msgSend)(settings, NSSelectorFromString(@"setHiDPI:"), hidpi);
    BOOL ok = ((BOOL(*)(id,SEL,id))objc_msgSend)(disp, NSSelectorFromString(@"applySettings:"), settings);
    if (!ok) return 0;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);
    uint32_t did = ((uint32_t(*)(id,SEL))objc_msgSend)(disp, NSSelectorFromString(@"displayID"));
    *keep = disp;
    return did;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        struct { uint32_t maxW, maxH, mW, mH, hi; const char *note; } tries[] = {
            {5120,2880, 5120,2880, 1, "max=5120x2880 mode=5120x2880 hiDPI=1"},
            {5120,2880, 5120,2880, 0, "max=5120x2880 mode=5120x2880 hiDPI=0"},
            {5120,2880, 2560,1440, 1, "max=5120x2880 mode=2560x1440 hiDPI=1"},
            {10240,5760, 5120,2880, 1, "max=10240x5760 mode=5120x2880 hiDPI=1"},
            {5120,2880, 2560,1440, 0, "max=5120x2880 mode=2560x1440 hiDPI=0"},
        };
        int only = -1;
        if (argc > 1) only = atoi(argv[1]);
        for (int i = 0; i < 5; i++) {
            if (only >= 0 && i != only) continue;
            id keep = nil;
            CGDirectDisplayID d = make(tries[i].maxW, tries[i].maxH, tries[i].mW, tries[i].mH,
                                       tries[i].hi, &keep);
            if (d) {
                printf("  %-40s -> %4zux%-4zu\n", tries[i].note,
                       CGDisplayPixelsWide(d), CGDisplayPixelsHigh(d));
            } else {
                printf("  %-40s -> FAILED\n", tries[i].note);
            }
            keep = nil;
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.4, false);
        }
        return 0;
    }
}
