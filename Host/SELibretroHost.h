#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Bit positions match RETRO_DEVICE_ID_JOYPAD_*.
typedef NS_OPTIONS(uint32_t, SEJoypadButtons) {
    SEJoypadButtonB      NS_SWIFT_NAME(b)      = 1u << 0,
    SEJoypadButtonY      NS_SWIFT_NAME(y)      = 1u << 1,
    SEJoypadButtonSelect NS_SWIFT_NAME(select) = 1u << 2,
    SEJoypadButtonStart  NS_SWIFT_NAME(start)  = 1u << 3,
    SEJoypadButtonUp     NS_SWIFT_NAME(up)     = 1u << 4,
    SEJoypadButtonDown   NS_SWIFT_NAME(down)   = 1u << 5,
    SEJoypadButtonLeft   NS_SWIFT_NAME(left)   = 1u << 6,
    SEJoypadButtonRight  NS_SWIFT_NAME(right)  = 1u << 7,
    SEJoypadButtonA      NS_SWIFT_NAME(a)      = 1u << 8,
    SEJoypadButtonX      NS_SWIFT_NAME(x)      = 1u << 9,
    SEJoypadButtonL      NS_SWIFT_NAME(l)      = 1u << 10,
    SEJoypadButtonR      NS_SWIFT_NAME(r)      = 1u << 11,
};

/// Identifiers of the statically linked libretro cores (stable; used in save metadata).
FOUNDATION_EXPORT NSString *const SECoreIDSnes9x;
FOUNDATION_EXPORT NSString *const SECoreIDGambatte;
FOUNDATION_EXPORT NSString *const SECoreIDMGBA;
FOUNDATION_EXPORT NSString *const SECoreIDGenesisPlusGX;
FOUNDATION_EXPORT NSString *const SECoreIDBeetlePSX;

/// Thin libretro frontend. libretro cores use process-global callbacks,
/// so only one host may be active at a time.
@interface SELibretroHost : NSObject

@property (class, nonatomic, readonly, nullable) SELibretroHost *activeHost;
@property (class, nonatomic, readonly) NSArray<NSString *> *availableCoreIDs;

- (nullable instancetype)initWithCoreID:(NSString *)coreID
                                 romURL:(NSURL *)romURL
                             saveRAMURL:(NSURL *)saveRAMURL
                        systemDirectory:(NSURL *)systemDirectory
                                  error:(NSError **)error NS_SWIFT_NAME(init(coreID:romURL:saveRAMURL:systemDirectory:)) NS_DESIGNATED_INITIALIZER;
/// Snes9x, kept for existing callers.
- (nullable instancetype)initWithROMURL:(NSURL *)romURL
                             saveRAMURL:(NSURL *)saveRAMURL
                        systemDirectory:(NSURL *)systemDirectory
                                  error:(NSError **)error NS_SWIFT_NAME(init(romURL:saveRAMURL:systemDirectory:));
- (instancetype)init NS_UNAVAILABLE;

/// Stable core identifier, e.g. "gambatte" (save metadata `coreID`).
@property (nonatomic, readonly, copy) NSString *coreID;
@property (nonatomic, readonly, copy) NSString *coreName;
/// Core's own version plus the pinned upstream commit, e.g. "v0.5.0 (d9d6cd0)" (save metadata `coreVersion`).
@property (nonatomic, readonly, copy) NSString *coreVersion;
/// Pinned upstream commit (short SHA) of the core this build links.
@property (nonatomic, readonly, copy) NSString *coreRevision;
@property (nonatomic, readonly) double framesPerSecond;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger frameWidth;
@property (nonatomic, readonly) NSInteger frameHeight;

/// Player 1 joypad state, read by the core during the next frame.
@property (atomic) SEJoypadButtons buttons;
/// Starts/stops AVAudioEngine output. Off by default (tests run silent).
@property (nonatomic) BOOL audioEnabled;

- (void)runFrame;
- (void)runFrames:(NSInteger)count;

/// Current frame as an XRGB8888 image, or NULL before the first frame.
- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED;
- (NSData *)frameBufferData;

- (nullable NSData *)serializeState;
- (BOOL)unserializeState:(NSData *)state;
- (BOOL)saveStateToURL:(NSURL *)url error:(NSError **)error;
- (BOOL)loadStateFromURL:(NSURL *)url error:(NSError **)error;

/// Writes battery-backed SRAM (if the game has any) to saveRAMURL.
- (void)flushSaveRAM;
/// Flushes SRAM and unloads the core. Safe to call more than once.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
