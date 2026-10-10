#import "SELibretroHost.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#else
#import <OpenGL/OpenGL.h>
#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/gl3.h>
#endif
#include <dlfcn.h>
#include <os/lock.h>
#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "libretro.h"
#include "SECoreAPI.h"
#include "SELibretroHost+Testing.h"

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

/// Libretro hardware rendering (RETRO_ENVIRONMENT_SET_HW_RENDER): an offscreen OpenGL core-profile (macOS) or
/// OpenGL ES 3 (iOS) context. The core draws into `fbo`; each finished frame is blitted (flipped to top-left
/// origin) into an IOSurface-backed texture and copied into HostState::frame, so presentation is unchanged.
/// Where GL can't use an IOSurface (the iOS Simulator), the frame is read back with glReadPixels instead.
struct HardwareRender {
    retro_hw_render_callback callback = {};
    bool requested = false;
#if TARGET_OS_IPHONE
    EAGLContext *context = nil;
    CVOpenGLESTextureCacheRef textureCache = nullptr;
    CVOpenGLESTextureRef surfaceTexture = nullptr;
#else
    CGLContextObj context = nullptr;
#endif
    CVPixelBufferRef surface = nullptr;
    GLuint fbo = 0, color = 0, depth = 0, outFBO = 0, outTexture = 0;
    unsigned fbWidth = 0, fbHeight = 0, outWidth = 0, outHeight = 0;
    bool surfaceUnavailable = false;
    std::vector<uint32_t> readback;
};

struct HostState {
    retro_pixel_format pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    std::vector<uint32_t> frame;
    unsigned width = 0, height = 0;
    std::atomic<uint32_t> buttons[4] = {};
    /// [port][stick]: x in the low 16 bits, y in the high 16 bits.
    std::atomic<uint32_t> analog[4][2] = {};
    std::string systemDirectory, saveDirectory;
    AudioRing audio;
    std::atomic<bool> audioEnabled{false};
    bool active = false;
    const SECoreAPI *core = nullptr;
    /// Fields of the legacy interface are a prefix of the EXT one; unset callbacks stay null.
    retro_disk_control_ext_callback disk = {};
    HardwareRender hw;
    /// Defaults the core declared via SET_VARIABLES, answered when kCoreOptions doesn't override a key.
    std::vector<std::pair<std::string, std::string>> optionDefaults;
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
    {"mupen64plus_next", se_core_mupen64plus_next},
};

struct CoreOption {
    const char *key;
    const char *value;
};

const CoreOption kCoreOptions[] = {
    {"mupen64plus-rdp-plugin", "gliden64"},
    {"mupen64plus-rsp-plugin", "hle"},
    {"mupen64plus-cpucore", "cached_interpreter"},
    {"mupen64plus-ThreadedRenderer", "False"},
    // On macOS, GLideN64 frame buffer emulation only draws black through the offscreen FBO.
#if TARGET_OS_IPHONE
    {"mupen64plus-EnableFBEmulation", "True"},
#else
    {"mupen64plus-EnableFBEmulation", "False"},
#endif
};

std::vector<CoreEntry> &registeredCores() {
    static std::vector<CoreEntry> cores;
    return cores;
}

const SECoreAPI *coreNamed(NSString *identifier) {
    for (const CoreEntry &entry : kCores) {
        if ([identifier isEqualToString:@(entry.identifier)]) return entry.api();
    }
    for (const CoreEntry &entry : registeredCores()) {
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

bool hwMakeCurrent() {
#if TARGET_OS_IPHONE
    return g.hw.context && [EAGLContext setCurrentContext:g.hw.context];
#else
    return g.hw.context && CGLSetCurrentContext(g.hw.context) == kCGLNoError;
#endif
}

uintptr_t hwCurrentFramebuffer() { return g.hw.fbo; }

retro_proc_address_t hwProcAddress(const char *symbol) {
    return reinterpret_cast<retro_proc_address_t>(dlsym(RTLD_DEFAULT, symbol));
}

bool hwCreateContext(retro_hw_context_type type) {
#if TARGET_OS_IPHONE
    if (type != RETRO_HW_CONTEXT_OPENGLES3 && type != RETRO_HW_CONTEXT_OPENGLES_VERSION) return false;
    g.hw.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!g.hw.context) return false;
#else
    if (type != RETRO_HW_CONTEXT_OPENGL_CORE) return false;
    for (int accelerated = 1; accelerated >= 0 && !g.hw.context; accelerated--) {
        CGLPixelFormatAttribute attributes[] = {
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core),
            kCGLPFAColorSize, CGLPixelFormatAttribute(24), kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADepthSize, CGLPixelFormatAttribute(24), kCGLPFAAllowOfflineRenderers,
            accelerated ? kCGLPFAAccelerated : CGLPixelFormatAttribute(0), CGLPixelFormatAttribute(0),
        };
        CGLPixelFormatObj format = nullptr;
        GLint count = 0;
        if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || !format) continue;
        CGLCreateContext(format, nullptr, &g.hw.context);
        CGLReleasePixelFormat(format);
    }
    if (!g.hw.context) return false;
#endif
    return hwMakeCurrent();
}

void hwCreateFramebuffer(unsigned width, unsigned height) {
    g.hw.fbWidth = width;
    g.hw.fbHeight = height;
    glGenFramebuffers(1, &g.hw.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g.hw.fbo);
    glGenTextures(1, &g.hw.color);
    glBindTexture(GL_TEXTURE_2D, g.hw.color);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g.hw.color, 0);
    if (g.hw.callback.depth || g.hw.callback.stencil) {
        glGenRenderbuffers(1, &g.hw.depth);
        glBindRenderbuffer(GL_RENDERBUFFER, g.hw.depth);
        bool stencil = g.hw.callback.stencil;
        glRenderbufferStorage(GL_RENDERBUFFER, stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                                  GL_RENDERBUFFER, g.hw.depth);
    }
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

void hwReleaseOutput() {
    if (g.hw.outFBO) glDeleteFramebuffers(1, &g.hw.outFBO);
#if TARGET_OS_IPHONE
    if (g.hw.surfaceTexture) CFRelease(g.hw.surfaceTexture);
    g.hw.surfaceTexture = nullptr;
#else
    if (g.hw.outTexture) glDeleteTextures(1, &g.hw.outTexture);
#endif
    if (g.hw.surface) CVPixelBufferRelease(g.hw.surface);
    g.hw.surface = nullptr;
    g.hw.outFBO = g.hw.outTexture = 0;
    g.hw.outWidth = g.hw.outHeight = 0;
}

/// IOSurface-backed BGRA target the size of the visible frame.
bool hwEnsureOutput(unsigned width, unsigned height) {
    if (g.hw.outFBO && g.hw.outWidth == width && g.hw.outHeight == height) return true;
    hwReleaseOutput();
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
#if TARGET_OS_IPHONE
                                 (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
#else
                                 (id)kCVPixelBufferOpenGLCompatibilityKey: @YES,
#endif
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &g.hw.surface) != kCVReturnSuccess) return false;
#if TARGET_OS_IPHONE
    if (!g.hw.textureCache &&
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nullptr, g.hw.context, nullptr, &g.hw.textureCache) != kCVReturnSuccess)
        return false;
    if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g.hw.textureCache, g.hw.surface, nullptr,
                                                     GL_TEXTURE_2D, GL_RGBA, width, height, GL_BGRA_EXT,
                                                     GL_UNSIGNED_BYTE, 0, &g.hw.surfaceTexture) != kCVReturnSuccess)
        return false;
    GLenum target = CVOpenGLESTextureGetTarget(g.hw.surfaceTexture);
    g.hw.outTexture = CVOpenGLESTextureGetName(g.hw.surfaceTexture);
    glBindTexture(target, g.hw.outTexture);
#else
    GLenum target = GL_TEXTURE_RECTANGLE;
    glGenTextures(1, &g.hw.outTexture);
    glBindTexture(target, g.hw.outTexture);
    if (CGLTexImageIOSurface2D(g.hw.context, target, GL_RGBA, width, height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                               CVPixelBufferGetIOSurface(g.hw.surface), 0) != kCGLNoError)
        return false;
#endif
    glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenFramebuffers(1, &g.hw.outFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, g.hw.outFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, g.hw.outTexture, 0);
    bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    g.hw.outWidth = width;
    g.hw.outHeight = height;
    return complete;
}

void hwReadPixels(unsigned width, unsigned height) {
    g.hw.readback.resize(size_t(width) * height);
    GLint readFBO = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFBO);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g.hw.fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, g.hw.readback.data());
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFBO);
    for (unsigned y = 0; y < height; y++) {
        unsigned row = g.hw.callback.bottom_left_origin ? height - 1 - y : y;
        const uint32_t *src = &g.hw.readback[size_t(row) * width];
        uint32_t *dst = &g.frame[size_t(y) * width];
        for (unsigned x = 0; x < width; x++) {
            uint32_t v = src[x];
            dst[x] = 0xFF000000u | ((v & 0xFFu) << 16) | (v & 0xFF00u) | ((v >> 16) & 0xFFu);
        }
    }
}

void hwCaptureFrame(unsigned width, unsigned height) {
    width = std::min(width, g.hw.fbWidth);
    height = std::min(height, g.hw.fbHeight);
    if (width == 0 || height == 0) return;
    if (!g.hw.surfaceUnavailable && !hwEnsureOutput(width, height)) {
        hwReleaseOutput();
        g.hw.surfaceUnavailable = true;
    }
    if (g.width != width || g.height != height) {
        g.frame.assign(size_t(width) * height, 0);
        g.width = width;
        g.height = height;
    }
    if (g.hw.surfaceUnavailable) {
        hwReadPixels(width, height);
        return;
    }
    GLint readFBO = 0, drawFBO = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFBO);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFBO);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g.hw.fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g.hw.outFBO);
    if (g.hw.callback.bottom_left_origin)
        glBlitFramebuffer(0, 0, width, height, 0, height, width, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    else
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glFinish();
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFBO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFBO);

    CVPixelBufferLockBaseAddress(g.hw.surface, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(g.hw.surface));
    size_t stride = CVPixelBufferGetBytesPerRow(g.hw.surface);
    for (unsigned y = 0; y < height; y++) {
        const uint32_t *src = reinterpret_cast<const uint32_t *>(base + y * stride);
        uint32_t *dst = &g.frame[size_t(y) * width];
        for (unsigned x = 0; x < width; x++) dst[x] = src[x] | 0xFF000000u;
    }
    CVPixelBufferUnlockBaseAddress(g.hw.surface, kCVPixelBufferLock_ReadOnly);
}

/// Called after load_game with the context current: allocates the core's framebuffer and runs context_reset.
void hwStart(const retro_system_av_info &av) {
    if (!g.hw.requested || !hwMakeCurrent()) return;
    hwCreateFramebuffer(std::max(av.geometry.max_width, 1u), std::max(av.geometry.max_height, 1u));
    if (g.hw.callback.context_reset) g.hw.callback.context_reset();
}

void hwDestroy() {
    if (!g.hw.requested) return;
    if (hwMakeCurrent()) {
        if (g.hw.callback.context_destroy) g.hw.callback.context_destroy();
        hwReleaseOutput();
        if (g.hw.fbo) glDeleteFramebuffers(1, &g.hw.fbo);
        if (g.hw.color) glDeleteTextures(1, &g.hw.color);
        if (g.hw.depth) glDeleteRenderbuffers(1, &g.hw.depth);
    }
#if TARGET_OS_IPHONE
    if (g.hw.textureCache) CFRelease(g.hw.textureCache);
    [EAGLContext setCurrentContext:nil];
#else
    CGLSetCurrentContext(nullptr);
    if (g.hw.context) CGLDestroyContext(g.hw.context);
#endif
    g.hw = HardwareRender();
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
        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
            *static_cast<unsigned *>(data) = 1;
            return true;
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE: {
            // Cores may pass NULL to withdraw the interface (Genesis Plus GX does for cartridges).
            g.disk = {};
            if (auto cb = static_cast<const retro_disk_control_callback *>(data)) {
                g.disk.set_eject_state = cb->set_eject_state;
                g.disk.get_eject_state = cb->get_eject_state;
                g.disk.get_image_index = cb->get_image_index;
                g.disk.set_image_index = cb->set_image_index;
                g.disk.get_num_images = cb->get_num_images;
                g.disk.replace_image_index = cb->replace_image_index;
                g.disk.add_image_index = cb->add_image_index;
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
            g.disk = {};
            if (data) g.disk = *static_cast<const retro_disk_control_ext_callback *>(data);
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            auto variable = static_cast<retro_variable *>(data);
            for (const CoreOption &option : kCoreOptions) {
                if (variable->key && strcmp(variable->key, option.key) == 0) {
                    variable->value = option.value;
                    return true;
                }
            }
            for (const auto &option : g.optionDefaults) {
                if (variable->key && option.first == variable->key) {
                    variable->value = option.second.c_str();
                    return true;
                }
            }
            return false;
        }
        case RETRO_ENVIRONMENT_SET_VARIABLES: {
            // Each value is "Description; default|other|...".
            g.optionDefaults.clear();
            for (auto v = static_cast<const retro_variable *>(data); v && v->key; v++) {
                const char *values = v->value ? strstr(v->value, "; ") : nullptr;
                if (!values) continue;
                std::string value(values + 2);
                g.optionDefaults.emplace_back(v->key, value.substr(0, value.find('|')));
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SET_HW_RENDER: {
            auto callback = static_cast<retro_hw_render_callback *>(data);
            if (!g.hw.context && !hwCreateContext(callback->context_type)) return false;
            callback->get_current_framebuffer = hwCurrentFramebuffer;
            callback->get_proc_address = hwProcAddress;
            g.hw.callback = *callback;
            g.hw.requested = true;
            return true;
        }
        default:
            return false;
    }
}

inline uint32_t expand5(uint32_t v) { return (v << 3) | (v >> 2); }
inline uint32_t expand6(uint32_t v) { return (v << 2) | (v >> 4); }

void videoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        hwCaptureFrame(width, height);
        return;
    }
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

constexpr unsigned kPortCount = 4;

void resetInput() {
    for (unsigned port = 0; port < kPortCount; port++) {
        g.buttons[port] = 0;
        g.analog[port][0] = 0;
        g.analog[port][1] = 0;
    }
}

int16_t inputStateCallback(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port >= kPortCount) return 0;
    uint32_t buttons = g.buttons[port].load();
    switch (device & RETRO_DEVICE_MASK) {
    case RETRO_DEVICE_JOYPAD:
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return int16_t(buttons & 0xFFFF);
        return id < 16 ? (buttons >> id) & 1 : 0;
    case RETRO_DEVICE_ANALOG:
        if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON) return id < 16 && ((buttons >> id) & 1) ? 0x7FFF : 0;
        if (index > RETRO_DEVICE_INDEX_ANALOG_RIGHT || id > RETRO_DEVICE_ID_ANALOG_Y) return 0;
        {
            uint32_t packed = g.analog[port][index].load();
            return int16_t(uint16_t(id == RETRO_DEVICE_ID_ANALOG_X ? packed & 0xFFFF : packed >> 16));
        }
    default:
        return 0;
    }
}

NSError *hostError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SupersEmu.LibretroHost" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

} // namespace

void SELibretroHostRegisterCore(const char *identifier, const SECoreAPI *(*api)(void)) {
    registeredCores().push_back({identifier, api});
}

const NSInteger SEInputPortCount = kPortCount;

NSString *const SECoreIDSnes9x = @"snes9x";
NSString *const SECoreIDGambatte = @"gambatte";
NSString *const SECoreIDMGBA = @"mgba";
NSString *const SECoreIDGenesisPlusGX = @"genesis_plus_gx";
NSString *const SECoreIDBeetlePSX = @"beetle_psx";
NSString *const SECoreIDPicoDrive = @"picodrive";
NSString *const SECoreIDMupen64PlusNext = @"mupen64plus_next";

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
    resetInput();
    g.core = core;
    g.disk = {};
    g.optionDefaults.clear();
    g.hw = HardwareRender();

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
        if (g.hw.requested) hwMakeCurrent();
        core->deinit();
        hwDestroy();
        g.core = nullptr;
        g.disk = {};
        if (error) *error = hostError(2, @"The emulator could not load this game.");
        return nil;
    }
    core->set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    core->get_system_av_info(&_avInfo);
    hwStart(_avInfo);

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
- (SEJoypadButtons)buttons { return g.buttons[0].load(); }
- (void)setButtons:(SEJoypadButtons)buttons { g.buttons[0] = buttons; }

- (SEJoypadButtons)buttonsForPort:(NSInteger)port {
    return port >= 0 && port < SEInputPortCount ? g.buttons[port].load() : 0;
}

- (void)setButtons:(SEJoypadButtons)buttons forPort:(NSInteger)port {
    if (port >= 0 && port < SEInputPortCount) g.buttons[port] = buttons;
}

- (void)setAnalogStick:(SEAnalogStick)stick x:(int16_t)x y:(int16_t)y forPort:(NSInteger)port {
    if (port < 0 || port >= SEInputPortCount || (stick != SEAnalogStickLeft && stick != SEAnalogStickRight)) return;
    g.analog[port][stick] = uint32_t(uint16_t(x)) | (uint32_t(uint16_t(y)) << 16);
}

- (void)runFrame {
    if (!_loaded) return;
    if (g.hw.requested) hwMakeCurrent();
    g.core->run();
}

- (void)runFrames:(NSInteger)count {
    for (NSInteger i = 0; i < count; i++) [self runFrame];
}

- (NSInteger)diskCount {
    return _loaded && g.disk.get_num_images ? NSInteger(g.disk.get_num_images()) : 0;
}

- (NSInteger)currentDisk {
    return _loaded && g.disk.get_image_index ? NSInteger(g.disk.get_image_index()) : 0;
}

- (NSString *)labelForDisk:(NSInteger)index {
    if (!_loaded || !g.disk.get_image_label || index < 0 || index >= self.diskCount) return nil;
    char label[256] = {};
    if (!g.disk.get_image_label(unsigned(index), label, sizeof label) || label[0] == 0) return nil;
    return [NSString stringWithUTF8String:label];
}

- (BOOL)insertDisk:(NSInteger)index error:(NSError **)error {
    const retro_disk_control_ext_callback &disk = g.disk;
    NSInteger count = self.diskCount;
    if (!disk.set_eject_state || !disk.set_image_index || count < 1) {
        if (error) *error = hostError(6, @"This game can't change discs.");
        return NO;
    }
    if (index < 0 || index >= count) {
        if (error) *error = hostError(7, [NSString stringWithFormat:@"There is no disc %ld.", long(index + 1)]);
        return NO;
    }
    // Cores only accept a new image while the tray is open: eject, set the index, close.
    BOOL wasOpen = disk.get_eject_state && disk.get_eject_state();
    if (!wasOpen && !disk.set_eject_state(true)) {
        if (error) *error = hostError(8, @"The emulator couldn't open the disc tray.");
        return NO;
    }
    bool inserted = disk.set_image_index(unsigned(index));
    // Close the tray even if the swap failed so the previous disc keeps running.
    bool closed = disk.set_eject_state(false);
    if (!inserted || !closed) {
        if (error) *error = hostError(8, [NSString stringWithFormat:@"The emulator couldn't insert disc %ld.", long(index + 1)]);
        return NO;
    }
    return YES;
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
    if (g.hw.requested) hwMakeCurrent();
    size_t size = g.core->serialize_size();
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return g.core->serialize(data.mutableBytes, size) ? data : nil;
}

- (BOOL)unserializeState:(NSData *)state {
    if (_loaded && g.hw.requested) hwMakeCurrent();
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
    if (g.hw.requested) hwMakeCurrent();
    g.core->unload_game();
    g.core->deinit();
    hwDestroy();
    g.core = nullptr;
    g.disk = {};
    _loaded = NO;
    g.active = false;
    g.audioEnabled = false;
    if (gActiveHost == self) gActiveHost = nil;
}

@end
