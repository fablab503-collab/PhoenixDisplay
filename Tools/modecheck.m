#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
// Does setModes: actually stick on CGVirtualDisplaySettings?
int main(void) {
    @autoreleasepool {
        Class mc = NSClassFromString(@"CGVirtualDisplayMode");
        CFTypeRef ma = ((CFTypeRef(*)(Class,SEL))objc_msgSend)(mc, NSSelectorFromString(@"alloc"));
        id mode = CFBridgingRelease(((CFTypeRef(*)(CFTypeRef,SEL,uint32_t,uint32_t,double))objc_msgSend)
                     (ma, NSSelectorFromString(@"initWithWidth:height:refreshRate:"), 2560, 1440, 60.0));
        printf("  mode object: %s\n", mode ? "created" : "NIL");
        if (mode) {
            for (NSString *g in @[@"width", @"height", @"refreshRate"]) {
                SEL sel = NSSelectorFromString(g);
                if ([mode respondsToSelector:sel]) {
                    if ([g isEqualToString:@"refreshRate"]) {
                        double v = ((double(*)(id,SEL))objc_msgSend)(mode, sel);
                        printf("    %s = %.1f\n", g.UTF8String, v);
                    } else {
                        uint32_t v = ((uint32_t(*)(id,SEL))objc_msgSend)(mode, sel);
                        printf("    %s = %u\n", g.UTF8String, v);
                    }
                } else printf("    %s: NO GETTER\n", g.UTF8String);
            }
        }
        Class sc = NSClassFromString(@"CGVirtualDisplaySettings");
        id st = [[sc alloc] init];
        printf("  responds to setModes: %d, modes: %d\n",
               [st respondsToSelector:NSSelectorFromString(@"setModes:")],
               [st respondsToSelector:NSSelectorFromString(@"modes")]);
        ((void(*)(id,SEL,id))objc_msgSend)(st, NSSelectorFromString(@"setModes:"), @[mode]);
        id back = ((id(*)(id,SEL))objc_msgSend)(st, NSSelectorFromString(@"modes"));
        printf("  modes read back: %lu\n", (unsigned long)[back count]);
        return 0;
    }
}
