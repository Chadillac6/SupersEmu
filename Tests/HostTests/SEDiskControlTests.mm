#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include <string>
#include <vector>
#include "SELibretroHost+Testing.h"

// A stub libretro core with a three-disc tray. It enforces the libretro rule that images can
// only change while the tray is open, and records every disk-control call in order.
namespace stub {

enum class Mode { ext, legacy, none };

Mode mode = Mode::ext;
unsigned imageCount = 3;
unsigned imageIndex = 0;
bool ejected = false;
std::vector<std::string> calls;
std::string loadedPath;
bool receivedData = false;
bool rejectIndex = false;
retro_environment_t environment = nullptr;
retro_video_refresh_t video = nullptr;
uint16_t pixels[16] = {};

bool RETRO_CALLCONV setEject(bool value) { calls.push_back(value ? "eject" : "close"); ejected = value; return true; }
bool RETRO_CALLCONV getEject() { return ejected; }
unsigned RETRO_CALLCONV getIndex() { return imageIndex; }
bool RETRO_CALLCONV setIndex(unsigned index) {
    calls.push_back("index " + std::to_string(index));
    if (rejectIndex || !ejected || index >= imageCount) return false;
    imageIndex = index;
    return true;
}
unsigned RETRO_CALLCONV numImages() { return imageCount; }
bool RETRO_CALLCONV replaceImage(unsigned, const retro_game_info *) { return false; }
bool RETRO_CALLCONV addImage() { return false; }
bool RETRO_CALLCONV setInitial(unsigned, const char *) { return false; }
bool RETRO_CALLCONV imagePath(unsigned, char *, size_t) { return false; }
bool RETRO_CALLCONV imageLabel(unsigned index, char *s, size_t len) {
    snprintf(s, len, "Stub Disc %u", index + 1);
    return true;
}

void setEnvironment(retro_environment_t cb) { environment = cb; }
void setVideo(retro_video_refresh_t cb) { video = cb; }
void setAudio(retro_audio_sample_t) {}
void setAudioBatch(retro_audio_sample_batch_t) {}
void setInputPoll(retro_input_poll_t) {}
void setInputState(retro_input_state_t) {}
void init() {}
void deinit() {}
void systemInfo(retro_system_info *info) {
    info->library_name = "Stub Disc";
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
size_t serializeSize() { return 4; }
bool serialize(void *data, size_t size) { memcpy(data, &imageIndex, size); return true; }
bool unserialize(const void *, size_t) { return true; }
bool loadGame(const retro_game_info *game) {
    loadedPath = game->path ?: "";
    receivedData = game->data != nullptr;
    unsigned version = 0;
    environment(RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION, &version);
    if (mode == Mode::ext && version >= 1) {
        static retro_disk_control_ext_callback ext = {setEject, getEject, getIndex, setIndex, numImages,
                                                      replaceImage, addImage, setInitial, imagePath, imageLabel};
        environment(RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, &ext);
    } else if (mode == Mode::legacy) {
        static retro_disk_control_callback legacy = {setEject, getEject, getIndex, setIndex, numImages, replaceImage, addImage};
        environment(RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, &legacy);
    } else {
        environment(RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, nullptr);
    }
    return true;
}
void unloadGame() {}
void *memoryData(unsigned) { return nullptr; }
size_t memorySize(unsigned) { return 0; }

const SECoreAPI table = {
    "stub_disc", "test", setEnvironment, setVideo, setAudio, setAudioBatch, setInputPoll, setInputState,
    init, deinit, systemInfo, avInfo, setPort, run, serializeSize, serialize, unserialize, loadGame,
    unloadGame, memoryData, memorySize,
};
const SECoreAPI *api() { return &table; }

void reset(Mode newMode) {
    mode = newMode;
    imageCount = 3;
    imageIndex = 0;
    ejected = false;
    calls.clear();
    loadedPath.clear();
    receivedData = false;
    rejectIndex = false;
}

} // namespace stub

@interface SEDiskControlTests : XCTestCase
@end

@implementation SEDiskControlTests {
    NSURL *_directory;
    NSURL *_playlist;
}

+ (void)setUp {
    SELibretroHostRegisterCore("stub_disc", stub::api);
}

- (void)setUp {
    _directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _playlist = [_directory URLByAppendingPathComponent:@"Game.m3u"];
    [@"Game (Disc 1).cue\nGame (Disc 2).cue\nGame (Disc 3).cue\n" writeToURL:_playlist atomically:YES encoding:NSUTF8StringEncoding error:nil];
    stub::reset(stub::Mode::ext);
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}

- (SELibretroHost *)makeHost {
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:@"stub_disc" romURL:_playlist
                                                       saveRAMURL:[_directory URLByAppendingPathComponent:@"Saves/game.srm"]
                                                  systemDirectory:[_directory URLByAppendingPathComponent:@"System"]
                                                            error:&error];
    XCTAssertNotNil(host, @"%@", error);
    return host;
}

- (void)testDiscCorePassesPathOnly {
    [self makeHost];
    XCTAssertEqual(stub::loadedPath, std::string(_playlist.fileSystemRepresentation));
    XCTAssertFalse(stub::receivedData, @"need_fullpath cores must not receive the image bytes");
}

- (void)testExtInterfaceReportsDiscsAndLabels {
    SELibretroHost *host = [self makeHost];
    XCTAssertEqual(host.diskCount, 3);
    XCTAssertEqual(host.currentDisk, 0);
    XCTAssertEqualObjects([host labelForDisk:1], @"Stub Disc 2");
    XCTAssertNil([host labelForDisk:3]);
}

- (void)testInsertDiskEjectsSwapsAndClosesTray {
    SELibretroHost *host = [self makeHost];
    NSError *error = nil;
    XCTAssertTrue([host insertDisk:2 error:&error], @"%@", error);
    XCTAssertEqual(host.currentDisk, 2);
    XCTAssertFalse(stub::ejected);
    std::vector<std::string> expected = {"eject", "index 2", "close"};
    XCTAssertTrue(stub::calls == expected);
    [host runFrame];
}

- (void)testInsertDiskWhileTrayOpenSkipsEject {
    SELibretroHost *host = [self makeHost];
    stub::ejected = true;
    XCTAssertTrue([host insertDisk:1 error:nil]);
    std::vector<std::string> expected = {"index 1", "close"};
    XCTAssertTrue(stub::calls == expected);
    XCTAssertEqual(host.currentDisk, 1);
}

- (void)testInsertDiskRejectsOutOfRange {
    SELibretroHost *host = [self makeHost];
    NSError *error = nil;
    XCTAssertFalse([host insertDisk:3 error:&error]);
    XCTAssertEqual(error.code, 7);
    XCTAssertFalse([host insertDisk:-1 error:nil]);
    XCTAssertTrue(stub::calls.empty(), @"no tray changes for an invalid disc");
    XCTAssertEqual(host.currentDisk, 0);
}

- (void)testFailedSwapClosesTrayOnPreviousDisc {
    SELibretroHost *host = [self makeHost];
    stub::rejectIndex = true;
    NSError *error = nil;
    XCTAssertFalse([host insertDisk:1 error:&error]);
    XCTAssertEqual(error.code, 8);
    std::vector<std::string> expected = {"eject", "index 1", "close"};
    XCTAssertTrue(stub::calls == expected);
    XCTAssertFalse(stub::ejected, @"the tray closes again on the previous disc");
    XCTAssertEqual(host.currentDisk, 0);
}

- (void)testLegacyInterface {
    stub::reset(stub::Mode::legacy);
    SELibretroHost *host = [self makeHost];
    XCTAssertEqual(host.diskCount, 3);
    XCTAssertNil([host labelForDisk:0], @"labels need the EXT interface");
    XCTAssertTrue([host insertDisk:1 error:nil]);
    XCTAssertEqual(host.currentDisk, 1);
}

- (void)testCoreWithoutDiskControl {
    stub::reset(stub::Mode::none);
    SELibretroHost *host = [self makeHost];
    XCTAssertEqual(host.diskCount, 0);
    NSError *error = nil;
    XCTAssertFalse([host insertDisk:0 error:&error]);
    XCTAssertEqual(error.code, 6);
}

- (void)testShutdownClearsDiskControl {
    SELibretroHost *host = [self makeHost];
    XCTAssertEqual(host.diskCount, 3);
    [host shutdown];
    XCTAssertEqual(host.diskCount, 0);
    stub::reset(stub::Mode::none);
    SELibretroHost *next = [self makeHost];
    XCTAssertEqual(next.diskCount, 0, @"a previous core's callbacks must not leak into the next game");
}

@end
