#import "SELibretroHost.h"
#import <AVFoundation/AVFoundation.h>
#include <os/lock.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "libretro.h"
#include "SECoreAPI.h"

namespace {

struct AudioRing {
    std::vector<int16_t> samples;
    size_t capacity = 0, readIndex = 0, writeIndex = 0, count = 0;
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

    void reset(size_t frames) {
        os_unfair_lock_lock(&lock);
        samples.assign(frames * 2, 0);
        capacity = frames;
        readIndex = writeIndex = count = 0;
        os_unfair_lock_unlock(&lock);
    }

    void push(const int16_t *data, size_t frames) {
        os_unfair_lock_lock(&lock);
        if (capacity > 0) {
            for (size_t i = 0; i < frames; i++) {
                if (count == capacity) { readIndex = (readIndex + 1) % capacity; count--; }
                samples[writeIndex * 2] = data[i * 2];
                samples[writeIndex * 2 + 1] = data[i * 2 + 1];
                writeIndex = (writeIndex + 1) % capacity;
                count++;
            }
        }
        os_unfair_lock_unlock(&lock);
    }

    void pop(float *left, float *right, size_t frames) {
        os_unfair_lock_lock(&lock);
        size_t i = 0;
        for (; i < frames && count > 0; i++) {
            float l = samples[readIndex * 2] / 32768.0f;
            float r = samples[readIndex * 2 + 1] / 32768.0f;
            if (left == right) { left[i] = (l + r) * 0.5f; } else { left[i] = l; right[i] = r; }
            readIndex = (readIndex + 1) % capacity;
            count--;
        }
        os_unfair_lock_unlock(&lock);
        for (; i < frames; i++) { left[i] = 0; right[i] = 0; }
    }
};

struct HostState {
    retro_pixel_format pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    std::vector<uint32_t> frame;
    unsigned width = 0, height = 0;
    std::atomic<uint32_t> buttons{0};
    std::string systemDirectory, saveDirectory;
    AudioRing audio;
    std::atomic<bool> audioEnabled{false};
    bool active = false;
    const SECoreAPI *core = nullptr;
};

struct CoreEntry {
    const char *identifier;
    const SECoreAPI *(*api)(void);
};

const CoreEntry kCores[] = {
    {"snes9x", se_core_snes9x},
    {"gambatte", se_core_gambatte},
    {"mgba", se_core_mgba},
    {"genesis_plus_gx", se_core_genesis_plus_gx},
    {"beetle_psx", se_core_beetle_psx},
    {"picodrive", se_core_picodrive},
};

const SECoreAPI *coreNamed(NSString *identifier) {
    for (const CoreEntry &entry : kCores) {
        if ([identifier isEqualToString:@(entry.identifier)]) return entry.api();
    }
    return nullptr;
}

HostState g;

void logCallback(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

bool environmentCallback(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            auto format = *static_cast<const retro_pixel_format *>(data);
            if (format == RETRO_PIXEL_FORMAT_XRGB8888 || format == RETRO_PIXEL_FORMAT_RGB565 ||
                format == RETRO_PIXEL_FORMAT_0RGB1555) {
                g.pixelFormat = format;
                return true;
            }
            return false;
        }
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *static_cast<const char **>(data) = g.systemDirectory.c_str();
            return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *static_cast<const char **>(data) = g.saveDirectory.c_str();
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            static_cast<retro_log_callback *>(data)->log = logCallback;
            return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *static_cast<bool *>(data) = true;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *static_cast<bool *>(data) = false;
            return true;
        default:
            return false;
    }
}

inline uint32_t expand5(uint32_t v) { return (v << 3) | (v >> 2); }
inline uint32_t expand6(uint32_t v) { return (v << 2) | (v >> 4); }

void videoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return;
    if (g.width != width || g.height != height) {
        g.frame.assign(size_t(width) * height, 0);
        g.width = width;
        g.height = height;
    }
    const uint8_t *src = static_cast<const uint8_t *>(data);
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = src + size_t(y) * pitch;
        uint32_t *dst = &g.frame[size_t(y) * width];
        switch (g.pixelFormat) {
            case RETRO_PIXEL_FORMAT_XRGB8888:
                for (unsigned x = 0; x < width; x++) dst[x] = reinterpret_cast<const uint32_t *>(row)[x] | 0xFF000000u;
                break;
            case RETRO_PIXEL_FORMAT_RGB565:
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = reinterpret_cast<const uint16_t *>(row)[x];
                    dst[x] = 0xFF000000u | expand5((p >> 11) & 0x1F) << 16 | expand6((p >> 5) & 0x3F) << 8 | expand5(p & 0x1F);
                }
                break;
            default:
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = reinterpret_cast<const uint16_t *>(row)[x];
                    dst[x] = 0xFF000000u | expand5((p >> 10) & 0x1F) << 16 | expand5((p >> 5) & 0x1F) << 8 | expand5(p & 0x1F);
                }
                break;
        }
    }
}

void audioSampleCallback(int16_t left, int16_t right) {
    if (!g.audioEnabled) return;
    int16_t frame[2] = {left, right};
    g.audio.push(frame, 1);
}

size_t audioBatchCallback(const int16_t *data, size_t frames) {
    if (g.audioEnabled) g.audio.push(data, frames);
    return frames;
}

void inputPollCallback() {}

int16_t inputStateCallback(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    uint32_t buttons = g.buttons.load();
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return int16_t(buttons & 0xFFFF);
    return (buttons >> id) & 1;
}

NSError *hostError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SupersEmu.LibretroHost" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

} // namespace

NSString *const SECoreIDSnes9x = @"snes9x";
NSString *const SECoreIDGambatte = @"gambatte";
NSString *const SECoreIDMGBA = @"mgba";
NSString *const SECoreIDGenesisPlusGX = @"genesis_plus_gx";
NSString *const SECoreIDBeetlePSX = @"beetle_psx";
NSString *const SECoreIDPicoDrive = @"picodrive";

static __weak SELibretroHost *gActiveHost;

@implementation SELibretroHost {
    NSData *_romData;
    NSURL *_saveRAMURL;
    retro_system_av_info _avInfo;
    BOOL _loaded;
    AVAudioEngine *_engine;
    AVAudioSourceNode *_sourceNode;
}

+ (SELibretroHost *)activeHost { return gActiveHost; }

+ (NSArray<NSString *> *)availableCoreIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (const CoreEntry &entry : kCores) [ids addObject:@(entry.identifier)];
    return ids;
}

- (instancetype)initWithROMURL:(NSURL *)romURL
                    saveRAMURL:(NSURL *)saveRAMURL
               systemDirectory:(NSURL *)systemDirectory
                         error:(NSError **)error {
    return [self initWithCoreID:SECoreIDSnes9x romURL:romURL saveRAMURL:saveRAMURL
                systemDirectory:systemDirectory error:error];
}

- (instancetype)initWithCoreID:(NSString *)coreID
                        romURL:(NSURL *)romURL
                    saveRAMURL:(NSURL *)saveRAMURL
               systemDirectory:(NSURL *)systemDirectory
                         error:(NSError **)error {
    const SECoreAPI *core = coreNamed(coreID);
    if (!core) {
        if (error) *error = hostError(5, [NSString stringWithFormat:@"No emulator core named \"%@\".", coreID]);
        return nil;
    }
    if (g.active) {
        if (error) *error = hostError(1, @"Another game is already running.");
        return nil;
    }
    self = [super init];
    if (!self) return nil;

    // Disc cores (need_fullpath) open the image themselves: don't read or map a multi-GB disc.
    retro_system_info preflight = {};
    core->get_system_info(&preflight);
    NSData *romData = nil;
    if (preflight.need_fullpath) {
        if (![romURL checkResourceIsReachableAndReturnError:error]) return nil;
    } else {
        romData = [NSData dataWithContentsOfURL:romURL options:NSDataReadingMappedIfSafe error:error];
        if (!romData) return nil;
    }

    NSURL *saveDirectory = saveRAMURL.URLByDeletingLastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:systemDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    g.systemDirectory = systemDirectory.fileSystemRepresentation;
    g.saveDirectory = saveDirectory.fileSystemRepresentation;
    g.pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    g.frame.clear();
    g.width = g.height = 0;
    g.buttons = 0;
    g.core = core;

    core->set_environment(environmentCallback);
    core->set_video_refresh(videoCallback);
    core->set_audio_sample(audioSampleCallback);
    core->set_audio_sample_batch(audioBatchCallback);
    core->set_input_poll(inputPollCallback);
    core->set_input_state(inputStateCallback);
    core->init();

    retro_system_info info = {};
    core->get_system_info(&info);
    _coreID = @(core->identifier);
    _coreRevision = @(core->revision);
    _coreName = [NSString stringWithUTF8String:info.library_name ?: "unknown"];
    NSString *libraryVersion = [[NSString stringWithUTF8String:info.library_version ?: "unknown"]
                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _coreVersion = [libraryVersion containsString:_coreRevision]
        ? libraryVersion : [NSString stringWithFormat:@"%@ (%@)", libraryVersion, _coreRevision];

    retro_game_info game = {};
    game.path = romURL.fileSystemRepresentation;
    if (romData) {
        game.data = romData.bytes;
        game.size = romData.length;
    }
    if (!core->load_game(&game)) {
        core->deinit();
        g.core = nullptr;
        if (error) *error = hostError(2, @"The emulator could not load this game.");
        return nil;
    }
    core->set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    core->get_system_av_info(&_avInfo);

    _romData = romData;
    _saveRAMURL = saveRAMURL;
    _loaded = YES;
    g.active = true;
    gActiveHost = self;
    g.audio.reset(size_t(_avInfo.timing.sample_rate / 4));
    [self loadSaveRAM];
    return self;
}

- (void)dealloc { [self shutdown]; }

- (double)framesPerSecond { return _avInfo.timing.fps; }
- (double)sampleRate { return _avInfo.timing.sample_rate; }
- (NSInteger)frameWidth { return g.width; }
- (NSInteger)frameHeight { return g.height; }
- (SEJoypadButtons)buttons { return g.buttons.load(); }
- (void)setButtons:(SEJoypadButtons)buttons { g.buttons = buttons; }

- (void)runFrame {
    if (_loaded) g.core->run();
}

- (void)runFrames:(NSInteger)count {
    for (NSInteger i = 0; i < count; i++) [self runFrame];
}

- (CGImageRef)copyFrameImage {
    if (g.width == 0 || g.height == 0) return NULL;
    CFDataRef data = CFDataCreate(NULL, reinterpret_cast<const UInt8 *>(g.frame.data()), CFIndex(g.frame.size() * 4));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(g.width, g.height, 8, 32, g.width * 4, colorSpace,
                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}

- (NSData *)frameBufferData {
    return [NSData dataWithBytes:g.frame.data() length:g.frame.size() * 4];
}

- (NSData *)serializeState {
    if (!_loaded) return nil;
    size_t size = g.core->serialize_size();
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return g.core->serialize(data.mutableBytes, size) ? data : nil;
}

- (BOOL)unserializeState:(NSData *)state {
    return _loaded && state.length > 0 && g.core->unserialize(state.bytes, state.length);
}

- (BOOL)saveStateToURL:(NSURL *)url error:(NSError **)error {
    NSData *state = [self serializeState];
    if (!state) {
        if (error) *error = hostError(3, @"The emulator could not create a save state.");
        return NO;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:nil];
    return [state writeToURL:url options:NSDataWritingAtomic error:error];
}

- (BOOL)loadStateFromURL:(NSURL *)url error:(NSError **)error {
    NSData *state = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!state) return NO;
    if (![self unserializeState:state]) {
        if (error) *error = hostError(4, @"This save state is not compatible with the current emulator.");
        return NO;
    }
    return YES;
}

- (void)loadSaveRAM {
    void *memory = g.core->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = g.core->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    NSData *saved = [NSData dataWithContentsOfURL:_saveRAMURL];
    if (memory && size > 0 && saved.length == size) memcpy(memory, saved.bytes, size);
}

- (void)flushSaveRAM {
    if (!_loaded) return;
    void *memory = g.core->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = g.core->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!memory || size == 0) return;
    [[NSData dataWithBytes:memory length:size] writeToURL:_saveRAMURL atomically:YES];
}

- (void)setAudioEnabled:(BOOL)audioEnabled {
    if (audioEnabled == _audioEnabled || !_loaded) return;
    _audioEnabled = audioEnabled;
    g.audioEnabled = audioEnabled;
    if (audioEnabled) {
        [self startAudio];
    } else {
        [_engine stop];
        _engine = nil;
        _sourceNode = nil;
    }
}

- (void)startAudio {
#if TARGET_OS_IPHONE
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
#endif
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:_avInfo.timing.sample_rate channels:2];
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *buffers) {
        float *left = static_cast<float *>(buffers->mBuffers[0].mData);
        float *right = buffers->mNumberBuffers > 1 ? static_cast<float *>(buffers->mBuffers[1].mData) : left;
        g.audio.pop(left, right, frameCount);
        return noErr;
    }];
    _engine = [[AVAudioEngine alloc] init];
    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode to:_engine.mainMixerNode format:format];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        NSLog(@"SupersEmu: audio unavailable: %@", error.localizedDescription);
    }
}

- (void)shutdown {
    if (!_loaded) return;
    [self flushSaveRAM];
    self.audioEnabled = NO;
    g.core->unload_game();
    g.core->deinit();
    g.core = nullptr;
    _loaded = NO;
    g.active = false;
    g.audioEnabled = false;
    if (gActiveHost == self) gActiveHost = nil;
}

@end
