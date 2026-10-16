#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

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
    SEJoypadButtonL2     NS_SWIFT_NAME(l2)     = 1u << 12,
    SEJoypadButtonR2     NS_SWIFT_NAME(r2)     = 1u << 13,
    SEJoypadButtonL3     NS_SWIFT_NAME(l3)     = 1u << 14,
    SEJoypadButtonR3     NS_SWIFT_NAME(r3)     = 1u << 15,
};

/// RETRO_DEVICE_INDEX_ANALOG_LEFT / _RIGHT.
typedef NS_ENUM(NSInteger, SEAnalogStick) {
    SEAnalogStickLeft = 0,
    SEAnalogStickRight = 1,
};

/// Controller ports the host feeds (players 1-4).
FOUNDATION_EXPORT const NSInteger SEInputPortCount;

/// Identifiers of the statically linked libretro cores (stable; used in save metadata).
FOUNDATION_EXPORT NSString *const SECoreIDSnes9x;
FOUNDATION_EXPORT NSString *const SECoreIDGambatte;
FOUNDATION_EXPORT NSString *const SECoreIDMGBA;
FOUNDATION_EXPORT NSString *const SECoreIDGenesisPlusGX;
FOUNDATION_EXPORT NSString *const SECoreIDBeetlePSX;
FOUNDATION_EXPORT NSString *const SECoreIDPicoDrive;
FOUNDATION_EXPORT NSString *const SECoreIDMupen64PlusNext;

/// Thin libretro frontend. libretro cores use process-global callbacks,
/// so only one host may be active at a time.
/// What happened to one code passed to -applyCheatCodes:.
typedef NS_ENUM(NSInteger, SECheatOutcome) {
    /// The core's cheat count went up: it took the code.
    SECheatOutcomeApplied = 0,
    /// The core ignored the code (or the core has no cheat support).
    SECheatOutcomeRejected = 1,
    /// Sent, but the core can't report whether it took it.
    SECheatOutcomeUnverified = 2,
} NS_SWIFT_NAME(CheatOutcome);

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
/// Cumulative since the game loaded; frames = stereo sample pairs.
@property (nonatomic, readonly) uint64_t audioUnderrunFrames;  // output pulled frames the ring didn't have (zero-filled)
@property (nonatomic, readonly) uint64_t audioOverflowFrames;  // oldest frames dropped because the ring was full
@property (nonatomic, readonly) NSInteger audioBufferedFrames;
/// "software", "gl-iosurface", "gl-readback" (IOSurface failed; glReadPixels each frame) or "gl-pending" before the first HW frame.
@property (nonatomic, readonly, copy) NSString *renderPath;
/// GL_RENDERER + GL_VERSION captured when the hardware context is created; nil for software cores.
@property (nonatomic, readonly, copy, nullable) NSString *graphicsRenderer;
/// Effective value of every option the core declared.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *coreOptions;
/// Overrides used by hosts created after this is set; keys the core does not declare are ignored.
@property (class, nonatomic, copy) NSDictionary<NSString *, NSString *> *pendingCoreOptionOverrides;
/// Every libretro log line (level = retro_log_level, 0 debug ... 3 error), called on the core thread.
@property (class, nonatomic, copy, nullable) void (^logHandler)(NSInteger level, NSString *message);

/// Player 1 joypad state, read by the core during the next frame.
@property (atomic) SEJoypadButtons buttons;
/// Joypad state for `port` (0 to SEInputPortCount - 1); other ports are ignored.
- (void)setButtons:(SEJoypadButtons)buttons forPort:(NSInteger)port NS_SWIFT_NAME(setButtons(_:port:));
- (SEJoypadButtons)buttonsForPort:(NSInteger)port NS_SWIFT_NAME(buttons(port:));
/// Analog stick for `port` (RETRO_DEVICE_ANALOG). Axes use libretro's range and direction:
/// -32768...32767, +x right, +y down.
- (void)setAnalogStick:(SEAnalogStick)stick x:(int16_t)x y:(int16_t)y forPort:(NSInteger)port NS_SWIFT_NAME(setAnalog(_:x:y:port:));
/// Starts/stops AVAudioEngine output. Off by default (tests run silent).
@property (nonatomic) BOOL audioEnabled;

- (void)runFrame;
- (void)runFrames:(NSInteger)count;
/// Resets the loaded core and clears held joypad and analog input.
- (void)reset;

/// Current frame as an XRGB8888 image, or NULL before the first frame.
- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED;
- (NSData *)frameBufferData;

- (nullable NSData *)serializeState;
- (BOOL)unserializeState:(NSData *)state;
- (BOOL)saveStateToURL:(NSURL *)url error:(NSError **)error;
- (BOOL)loadStateFromURL:(NSURL *)url error:(NSError **)error;

/// Discs the core exposes via RETRO_ENVIRONMENT_SET_DISK_CONTROL_(EXT_)INTERFACE
/// (an .m3u lists them); 0 when the core has no disk control.
@property (nonatomic, readonly) NSInteger diskCount;
/// Zero-based index of the inserted disc; >= diskCount when the tray is empty.
@property (nonatomic, readonly) NSInteger currentDisk;
/// The core's label for a disc (EXT interface only), else nil.
- (nullable NSString *)labelForDisk:(NSInteger)index;
/// Swaps to the zero-based disc `index`: opens the tray, selects the image, closes the tray.
- (BOOL)insertDisk:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(insertDisk(_:));

/// True when the loaded core takes cheat codes (retro_cheat_set).
@property (nonatomic, readonly) BOOL supportsCheats;
/// Replaces the core's cheats with `codes` (all enabled), sending one code per retro_cheat_set call.
/// Returns one SECheatOutcome per code, in order. An empty array clears every cheat.
- (NSArray<NSNumber *> *)applyCheatCodes:(NSArray<NSString *> *)codes NS_SWIFT_NAME(applyCheats(_:));

/// Writes battery-backed SRAM (if the game has any) to saveRAMURL.
- (void)flushSaveRAM;
/// Flushes SRAM and unloads the core. Safe to call more than once.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
