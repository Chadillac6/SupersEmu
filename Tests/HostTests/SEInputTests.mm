#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include "SELibretroHost+Testing.h"

// A stub core that reads input through the libretro callback the host installs, the way real cores do.
namespace inputstub {

retro_input_state_t inputState = nullptr;
retro_video_refresh_t video = nullptr;
uint16_t pixels[16] = {};

void setEnvironment(retro_environment_t) {}
void setVideo(retro_video_refresh_t cb) { video = cb; }
void setAudio(retro_audio_sample_t) {}
void setAudioBatch(retro_audio_sample_batch_t) {}
void setInputPoll(retro_input_poll_t) {}
void setInputState(retro_input_state_t cb) { inputState = cb; }
void init() {}
void deinit() {}
void systemInfo(retro_system_info *info) {
    info->library_name = "Stub Input";
    info->library_version = "1";
    info->need_fullpath = true;
}
void avInfo(retro_system_av_info *info) {
    *info = {};
    info->geometry.base_width = info->geometry.max_width = 4;
    info->geometry.base_height = info->geometry.max_height = 4;
    info->timing.fps = 60;
    info->timing.sample_rate = 44100;
}
void setPort(unsigned, unsigned) {}
void run() { if (video) video(pixels, 4, 4, 8); }
void reset() {}
size_t serializeSize() { return 0; }
bool serialize(void *, size_t) { return false; }
bool unserialize(const void *, size_t) { return false; }
bool loadGame(const retro_game_info *) { return true; }
void unloadGame() {}
void *memoryData(unsigned) { return nullptr; }
size_t memorySize(unsigned) { return 0; }

const SECoreAPI table = {
    "stub_input", "test", setEnvironment, setVideo, setAudio, setAudioBatch, setInputPoll, setInputState,
    init, deinit, systemInfo, avInfo, setPort, run, reset, serializeSize, serialize, unserialize, loadGame,
    unloadGame, memoryData, memorySize,
};
const SECoreAPI *api() { return &table; }

} // namespace inputstub

@interface SEInputTests : XCTestCase
@end

@implementation SEInputTests {
    NSURL *_directory;
    SELibretroHost *_host;
}

+ (void)setUp {
    SELibretroHostRegisterCore("stub_input", inputstub::api);
}

- (void)setUp {
    _directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *rom = [_directory URLByAppendingPathComponent:@"game.bin"];
    [[NSData dataWithBytes:"x" length:1] writeToURL:rom atomically:YES];
    NSError *error = nil;
    _host = [[SELibretroHost alloc] initWithCoreID:@"stub_input" romURL:rom
                                        saveRAMURL:[_directory URLByAppendingPathComponent:@"Saves/game.srm"]
                                   systemDirectory:[_directory URLByAppendingPathComponent:@"System"]
                                             error:&error];
    XCTAssertNotNil(_host, @"%@", error);
}

- (void)tearDown {
    [_host shutdown];
    _host = nil;
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}

static int16_t state(unsigned port, unsigned device, unsigned index, unsigned id) {
    return inputstub::inputState(port, device, index, id);
}

- (void)testJoypadButtonsArePerPort {
    _host.buttons = SEJoypadButtonB | SEJoypadButtonR3;
    [_host setButtons:SEJoypadButtonStart | SEJoypadButtonL2 forPort:2];
    XCTAssertEqual(state(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B), 1);
    XCTAssertEqual(state(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_R3), 1);
    XCTAssertEqual(state(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_START), 0);
    XCTAssertEqual(state(1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B), 0);
    XCTAssertEqual(state(2, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK),
                   int16_t((1 << RETRO_DEVICE_ID_JOYPAD_START) | (1 << RETRO_DEVICE_ID_JOYPAD_L2)));
    XCTAssertEqual([_host buttonsForPort:2], SEJoypadButtonStart | SEJoypadButtonL2);
    // Out-of-range ports are ignored, never written.
    [_host setButtons:SEJoypadButtonA forPort:SEInputPortCount];
    XCTAssertEqual(state(SEInputPortCount, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A), 0);
}

- (void)testAnalogSticksArePerPortAndStick {
    [_host setAnalogStick:SEAnalogStickLeft x:-32768 y:12345 forPort:0];
    [_host setAnalogStick:SEAnalogStickRight x:32767 y:-1 forPort:0];
    [_host setAnalogStick:SEAnalogStickLeft x:100 y:-200 forPort:3];
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X), -32768);
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_Y), 12345);
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_RIGHT, RETRO_DEVICE_ID_ANALOG_X), 32767);
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_RIGHT, RETRO_DEVICE_ID_ANALOG_Y), -1);
    XCTAssertEqual(state(3, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X), 100);
    XCTAssertEqual(state(3, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_Y), -200);
    XCTAssertEqual(state(1, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X), 0);
    // Subclassed devices (e.g. a DualShock) read the same state.
    XCTAssertEqual(state(0, RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 0), RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_Y), 12345);
}

- (void)testDigitalButtonsReadAsFullAnalogButtons {
    _host.buttons = SEJoypadButtonR2;
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_BUTTON, RETRO_DEVICE_ID_JOYPAD_R2), 0x7FFF);
    XCTAssertEqual(state(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_BUTTON, RETRO_DEVICE_ID_JOYPAD_L2), 0);
}

- (void)testInputResetsForTheNextGame {
    [_host setButtons:SEJoypadButtonA forPort:1];
    [_host setAnalogStick:SEAnalogStickLeft x:5 y:5 forPort:1];
    [_host shutdown];
    [self setUp];
    XCTAssertEqual(state(1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A), 0);
    XCTAssertEqual(state(1, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X), 0);
}

@end
