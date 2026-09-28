//  PhoenixVD.h — safe wrapper around the private CGVirtualDisplay API.
//
//  Everything here is dynamically dispatched and guarded. Apple renames and
//  removes these selectors between macOS releases (setMaxPixelsTall: became
//  setMaxPixelsHigh:, which is what crashed Phoenix Display 1.4 on macOS 27).
//  Nothing in this file may raise: every call is checked with
//  respondsToSelector: first and wrapped in @try/@catch as a second net.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Where the extra desktop sits relative to this Mac's main screen.
typedef NS_ENUM(NSInteger, PhoenixVDPosition) {
    PhoenixVDPositionRight = 0,
    PhoenixVDPositionLeft,
    PhoenixVDPositionAbove,
    PhoenixVDPositionBelow,
};

@interface PhoenixVD : NSObject

/// YES when this macOS build still exposes a usable CGVirtualDisplay.
+ (BOOL)isSupported;

/// Human-readable reason when isSupported is NO (or extend failed).
@property (class, readonly, copy, nullable) NSString *unavailableReason;

/// Creates a virtual display. Returns nil instead of raising on any failure.
/// `displayID` receives the CGDirectDisplayID when it succeeds.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                             position:(PhoenixVDPosition)position;

/// Moves an existing virtual desktop without recreating it.
- (BOOL)setPosition:(PhoenixVDPosition)position;

/// Makes this virtual desktop the main display — the one carrying the menu bar.
/// macOS defines "main" as the display whose origin is (0,0), so this shifts
/// every other display to keep the arrangement intact.
- (BOOL)makeMainDisplay;

/// Puts the menu bar back on the built-in panel.
+ (BOOL)restoreBuiltInAsMain;

@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) BOOL active;
/// YES when the display came up but macOS kept it mirrored anyway.
@property (nonatomic, readonly) BOOL mirroredAnyway;
/// Populated when init returns nil, so the UI can explain itself.
@property (nonatomic, readonly, copy, nullable) NSString *failureReason;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
