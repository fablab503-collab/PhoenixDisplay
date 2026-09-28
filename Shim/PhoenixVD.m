#import "PhoenixVD.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *_Nullable gUnavailableReason = nil;

/// Sends a setter that takes a single 32-bit unsigned int, if it exists.
/// Tries each candidate name in order so an Apple rename can't kill us.
static BOOL SetUInt(id obj, NSArray<NSString *> *names, uint32_t value) {
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        if (![obj respondsToSelector:sel]) continue;
        @try {
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(obj, sel, value);
            return YES;
        } @catch (NSException *e) { /* try the next name */ }
    }
    return NO;
}

static BOOL SetObject(id obj, NSArray<NSString *> *names, id value) {
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        if (![obj respondsToSelector:sel]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, value);
            return YES;
        } @catch (NSException *e) {}
    }
    return NO;
}

static BOOL SetSize(id obj, NSArray<NSString *> *names, CGSize value) {
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        if (![obj respondsToSelector:sel]) continue;
        @try {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(obj, sel, value);
            return YES;
        } @catch (NSException *e) {}
    }
    return NO;
}


/// macOS drops a freshly created virtual display into a mirror set with the
/// built-in panel, which is exactly why "extend" behaved like "mirror".
/// Break the mirror set and park the new display to the right of the main one.
/// Works out the origin that puts `newDisplay` on the chosen side of the main
/// screen. CoreGraphics uses a top-left origin with y growing downwards, so
/// "above" is a negative y.
static CGPoint PhoenixOriginFor(CGDirectDisplayID newDisplay, PhoenixVDPosition pos) {
    CGDirectDisplayID main = CGMainDisplayID();
    CGRect m = CGDisplayBounds(main);
    size_t w = CGDisplayPixelsWide(newDisplay);
    size_t h = CGDisplayPixelsHigh(newDisplay);
    switch (pos) {
        case PhoenixVDPositionLeft:
            return CGPointMake(CGRectGetMinX(m) - (CGFloat)w, CGRectGetMinY(m));
        case PhoenixVDPositionAbove:
            return CGPointMake(CGRectGetMinX(m), CGRectGetMinY(m) - (CGFloat)h);
        case PhoenixVDPositionBelow:
            return CGPointMake(CGRectGetMinX(m), CGRectGetMaxY(m));
        case PhoenixVDPositionRight:
        default:
            return CGPointMake(CGRectGetMaxX(m), CGRectGetMinY(m));
    }
}

static BOOL PhoenixUnmirror(CGDirectDisplayID newDisplay, PhoenixVDPosition pos) {
    CGDirectDisplayID online[16]; uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, online, &n) != kCGErrorSuccess) return NO;

    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) return NO;

    // Any display currently mirroring something gets detached from its set.
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = online[i];
        if (CGDisplayIsInMirrorSet(d) || CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay) {
            CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay);
        }
    }

    // Park it on the side the user asked for, rather than on top of the
    // existing desktop.
    if (CGMainDisplayID() != newDisplay) {
        CGPoint o = PhoenixOriginFor(newDisplay, pos);
        CGConfigureDisplayOrigin(config, newDisplay, (int32_t)o.x, (int32_t)o.y);
    }

    // ForSession, not Permanently: we must not rewrite the user's saved
    // display arrangement just because they streamed for a while.
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

@implementation PhoenixVD {
    id _display;          // CGVirtualDisplay
    uint32_t _displayID;
    BOOL _active;
    BOOL _mirroredAnyway;
    NSString *_failureReason;
}

+ (NSString *)unavailableReason { return gUnavailableReason; }

+ (BOOL)isSupported {
    // Force CoreGraphics in so the private classes are registered.
    static dispatch_once_t once;
    static BOOL supported = NO;
    dispatch_once(&once, ^{
        NSArray *needed = @[@"CGVirtualDisplay",
                            @"CGVirtualDisplayDescriptor",
                            @"CGVirtualDisplayMode",
                            @"CGVirtualDisplaySettings"];
        NSMutableArray *missing = [NSMutableArray array];
        for (NSString *c in needed) {
            if (!NSClassFromString(c)) [missing addObject:c];
        }
        if (missing.count) {
            gUnavailableReason = [NSString stringWithFormat:
                @"This macOS build no longer provides %@.",
                [missing componentsJoinedByString:@", "]];
            supported = NO;
            return;
        }
        // The descriptor must accept a width setter under one of its known
        // names, otherwise extend mode can't be configured at all.
        Class dc = NSClassFromString(@"CGVirtualDisplayDescriptor");
        id probe = nil;
        @try { probe = [[dc alloc] init]; } @catch (NSException *e) {}
        if (!probe) {
            gUnavailableReason = @"CGVirtualDisplayDescriptor could not be created.";
            supported = NO;
            return;
        }
        BOOL hasW = [probe respondsToSelector:NSSelectorFromString(@"setMaxPixelsWide:")];
        BOOL hasH = [probe respondsToSelector:NSSelectorFromString(@"setMaxPixelsHigh:")]
                 || [probe respondsToSelector:NSSelectorFromString(@"setMaxPixelsTall:")];
        if (!hasW || !hasH) {
            gUnavailableReason = @"The virtual-display size API changed in this macOS build.";
            supported = NO;
            return;
        }
        supported = YES;
    });
    return supported;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                             position:(PhoenixVDPosition)position {
    self = [super init];
    if (!self) return nil;

    if (![PhoenixVD isSupported]) {
        _failureReason = gUnavailableReason ?: @"Virtual displays are unavailable.";
        return self;   // caller checks .active
    }

    @try {
        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        id desc = [[descClass alloc] init];
        if (!desc) { _failureReason = @"Could not create the display descriptor."; return self; }

        SetObject(desc, @[@"setName:"], name);
        SetUInt(desc, @[@"setMaxPixelsWide:"], width);
        // The rename that crashed 1.4. New name first, old name as fallback.
        SetUInt(desc, @[@"setMaxPixelsHigh:", @"setMaxPixelsTall:"], height);
        // Physical size drives the default scaling; ~109 ppi keeps text sane.
        double mmW = (double)width / 109.0 * 25.4;
        double mmH = (double)height / 109.0 * 25.4;
        SetSize(desc, @[@"setSizeInMillimeters:"], CGSizeMake(mmW, mmH));
        SetUInt(desc, @[@"setVendorID:"], 0x3456);
        SetUInt(desc, @[@"setProductID:"], 0x1234);
        SetUInt(desc, @[@"setSerialNumber:", @"setSerialNum:"], 0x0001);
        SetObject(desc, @[@"setQueue:", @"setDispatchQueue:"], dispatch_get_main_queue());

        Class dispClass = NSClassFromString(@"CGVirtualDisplay");
        SEL initSel = NSSelectorFromString(@"initWithDescriptor:");
        CFTypeRef allocRaw = ((CFTypeRef (*)(Class, SEL))objc_msgSend)
                                (dispClass, NSSelectorFromString(@"alloc"));
        if (!allocRaw) { _failureReason = @"CGVirtualDisplay alloc failed."; return self; }
        if (![(__bridge id)allocRaw respondsToSelector:initSel]) {
            CFRelease(allocRaw);
            _failureReason = @"CGVirtualDisplay has no initWithDescriptor:.";
            return self;
        }
        CFTypeRef displayRaw = ((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)
                                  (allocRaw, initSel, desc);
        id display = CFBridgingRelease(displayRaw);
        if (!display) { _failureReason = @"The system refused to create a virtual display."; return self; }

        // Mode + settings
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        SEL modeSel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
        CFTypeRef modeAllocRaw = ((CFTypeRef (*)(Class, SEL))objc_msgSend)
                                    (modeClass, NSSelectorFromString(@"alloc"));
        if (!modeAllocRaw) { _failureReason = @"CGVirtualDisplayMode alloc failed."; return self; }
        if (![(__bridge id)modeAllocRaw respondsToSelector:modeSel]) {
            CFRelease(modeAllocRaw);
            _failureReason = @"CGVirtualDisplayMode has no initWithWidth:height:refreshRate:.";
            return self;
        }
        // The MODE is in POINTS; maxPixelsWide/High are in PIXELS. With HiDPI a
        // point is two pixels, so asking for a 5120x2880 mode AND HiDPI implies a
        // 10240x5760 backing, which exceeds maxPixels — CGVirtualDisplay then
        // silently discards the mode and hands back a default 1920x1080 desktop.
        uint32_t modeW = hiDPI ? width / 2 : width;
        uint32_t modeH = hiDPI ? height / 2 : height;
        CFTypeRef modeRaw = ((CFTypeRef (*)(CFTypeRef, SEL, uint32_t, uint32_t, double))objc_msgSend)
                               (modeAllocRaw, modeSel, modeW, modeH, refreshRate);
        id mode = CFBridgingRelease(modeRaw);
        if (!mode) { _failureReason = @"Could not build the display mode."; return self; }

        Class setClass = NSClassFromString(@"CGVirtualDisplaySettings");
        id settings = [[setClass alloc] init];
        if (!settings) { _failureReason = @"Could not create display settings."; return self; }
        SetObject(settings, @[@"setModes:"], @[mode]);
        SetUInt(settings, @[@"setHiDPI:"], hiDPI ? 1 : 0);

        SEL applySel = NSSelectorFromString(@"applySettings:");
        if (![display respondsToSelector:applySel]) {
            _failureReason = @"CGVirtualDisplay has no applySettings:.";
            return self;
        }
        BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, applySel, settings);
        if (!ok) { _failureReason = @"applySettings: was rejected by the system."; return self; }

        SEL idSel = NSSelectorFromString(@"displayID");
        if ([display respondsToSelector:idSel]) {
            _displayID = ((uint32_t (*)(id, SEL))objc_msgSend)(display, idSel);
        }
        _display = display;
        _active = YES;

        // Give the window server a moment to register the display, then take
        // it out of the mirror set macOS just put it in.
        if (_displayID != 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.35, false);
            if (!PhoenixUnmirror(_displayID, position)) {
                // Not fatal: the stream still works, it just mirrors.
                _mirroredAnyway = YES;
            } else {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
                _mirroredAnyway = CGDisplayIsInMirrorSet(_displayID) ? YES : NO;
            }
        }
    } @catch (NSException *e) {
        // Belt and braces: an unexpected selector change lands here instead of
        // killing the process the way 1.4 did.
        _failureReason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"unknown"];
        _active = NO;
        _display = nil;
    }
    return self;
}

- (uint32_t)displayID { return _displayID; }
- (BOOL)active { return _active; }
- (BOOL)mirroredAnyway { return _mirroredAnyway; }
- (NSString *)failureReason { return _failureReason; }

- (BOOL)setPosition:(PhoenixVDPosition)position {
    if (!_active || _displayID == 0) return NO;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) return NO;
    CGPoint o = PhoenixOriginFor(_displayID, position);
    CGConfigureDisplayOrigin(config, _displayID, (int32_t)o.x, (int32_t)o.y);
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

/// macOS decides the main display by origin: whichever display sits at (0,0)
/// owns the menu bar. So making X main means translating every display by -X.origin.
static BOOL PhoenixSetMain(CGDirectDisplayID target) {
    CGDirectDisplayID online[16]; uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, online, &n) != kCGErrorSuccess || n == 0) return NO;

    BOOL found = NO;
    for (uint32_t i = 0; i < n; i++) if (online[i] == target) found = YES;
    if (!found) return NO;

    CGRect t = CGDisplayBounds(target);
    if (t.origin.x == 0 && t.origin.y == 0) return YES;   // already main

    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) return NO;
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(online[i]);
        CGConfigureDisplayOrigin(config, online[i],
                                 (int32_t)(b.origin.x - t.origin.x),
                                 (int32_t)(b.origin.y - t.origin.y));
    }
    // ForSession, so the user's saved arrangement is not rewritten permanently.
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

- (BOOL)makeMainDisplay {
    if (!_active || _displayID == 0) return NO;
    return PhoenixSetMain(_displayID);
}

+ (BOOL)restoreBuiltInAsMain {
    CGDirectDisplayID online[16]; uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, online, &n) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(online[i])) return PhoenixSetMain(online[i]);
    }
    return NO;
}

- (void)invalidate {
    if (!_display) { _active = NO; _displayID = 0; return; }
    @try {
        _display = nil;
        // Releasing the object is what removes the display; let the window
        // server act on it before we report ourselves as gone.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    } @catch (NSException *e) {}
    _active = NO;
    _mirroredAnyway = NO;
    _displayID = 0;
}

- (void)dealloc { [self invalidate]; }

@end
