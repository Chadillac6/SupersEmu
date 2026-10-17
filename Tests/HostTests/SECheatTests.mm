#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include <string>
#include <vector>
#include "SELibretroHost+Testing.h"

// A stub core that accepts codes starting with "OK" and records every cheat call in order.
namespace cheatstub {
std::vector<std::string> calls;
unsigned held = 0;
retro_environment_t environment = nullptr;
retro_video_refresh_t video = nullptr;
uint16_t pixels[16] = {};
void cheatReset() { calls.push_back("reset"); held = 0; }
void cheatSet(unsigned index, bool enabled, const char *code) {
    calls.push_back("set " + std::to_string(index) + (enabled ? " on " : " off ") + code);
    if (strncmp(code, "OK", 2) == 0) held++;
}
unsigned cheatCount() { return held; }
void setEnvironment(retro_environment_t cb) { environment = cb; }
void setVideo(retro_video_refresh_t cb) { video = cb; }
void setAudio(retro_audio_sample_t) {}
void setAudioBatch(retro_audio_sample_batch_t) {}
void setInputPoll(retro_input_poll_t) {}
void setInputState(retro_input_state_t) {}
void init() {}
void deinit() {}
void systemInfo(retro_system_info *info) {
    info->library_name = "Stub Cheat";
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
size_t serializeSize() { return 4; }
bool serialize(void *data, size_t size) { memset(data, 0, size); return true; }
bool unserialize(const void *, size_t) { return true; }
bool loadGame(const retro_game_info *) { return true; }
void unloadGame() { calls.push_back("unload"); }
void *memoryData(unsigned) { return nullptr; }
size_t memorySize(unsigned) { return 0; }

const SECoreAPI *api() {
    static const SECoreAPI table = {
        "stub_cheat", "test", setEnvironment, setVideo, setAudio, setAudioBatch, setInputPoll, setInputState,
        init, deinit, systemInfo, avInfo, setPort, run, reset, serializeSize, serialize, unserialize,
        loadGame, unloadGame, memoryData, memorySize, cheatReset, cheatSet, cheatCount,
    };
    return &table;
}
const SECoreAPI *unverifiedAPI() {
    static SECoreAPI table = *api();
    table.identifier = "stub_cheat_unverified";
    table.cheat_count = nullptr;
    return &table;
}
const SECoreAPI *noCheatsAPI() {
    static SECoreAPI table = *api();
    table.identifier = "stub_no_cheats";
    table.cheat_reset = nullptr;
    table.cheat_set = nullptr;
    table.cheat_count = nullptr;
    return &table;
}
}  // namespace cheatstub

@interface SECheatTests : XCTestCase
@end

@implementation SECheatTests {
    NSURL *_directory;
    NSString *_fixtures;
}

+ (void)setUp {
    SELibretroHostRegisterCore("stub_cheat", cheatstub::api);
    SELibretroHostRegisterCore("stub_cheat_unverified", cheatstub::unverifiedAPI);
    SELibretroHostRegisterCore("stub_no_cheats", cheatstub::noCheatsAPI);
}

- (void)setUp {
    _directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _fixtures = NSProcessInfo.processInfo.environment[@"SUPERSEMU_FIXTURES"];
    if (!_fixtures) {
        NSString *here = [NSString stringWithUTF8String:__FILE__];
        _fixtures = [[here.stringByDeletingLastPathComponent stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Fixtures/local"];
    }
    cheatstub::calls.clear();
    cheatstub::held = 0;
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}

- (SELibretroHost *)stubHost:(NSString *)coreID {
    NSURL *rom = [_directory URLByAppendingPathComponent:@"game.bin"];
    [[NSData dataWithBytes:"rom" length:3] writeToURL:rom atomically:YES];
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:coreID romURL:rom
                                                       saveRAMURL:[_directory URLByAppendingPathComponent:@"game.srm"]
                                                  systemDirectory:_directory error:&error];
    XCTAssertNotNil(host, @"%@", error);
    return host;
}

- (SELibretroHost *)realHost:(NSString *)coreID rom:(NSString *)rom {
    NSString *path = [_fixtures stringByAppendingPathComponent:rom];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:coreID romURL:[NSURL fileURLWithPath:path]
                                                       saveRAMURL:[_directory URLByAppendingPathComponent:@"real.srm"]
                                                  systemDirectory:_directory error:&error];
    XCTAssertNotNil(host, @"%@", error);
    return host;
}

static NSArray<NSNumber *> *outcomes(std::initializer_list<SECheatOutcome> list) {
    NSMutableArray *array = [NSMutableArray array];
    for (SECheatOutcome outcome : list) [array addObject:@(outcome)];
    return array;
}

- (void)testLoadResetsCheatsSoAnotherGamesCodesNeverCarryOver {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    XCTAssertTrue(host.supportsCheats);
    XCTAssertEqual(cheatstub::calls, std::vector<std::string>({"reset"}));
}

- (void)testSendsOneCodePerCallAfterResetAndReportsEachOutcome {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    cheatstub::calls.clear();
    NSArray *result = [host applyCheatCodes:@[@"OK-1", @"BAD", @"OK-2"]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeApplied, SECheatOutcomeRejected, SECheatOutcomeApplied}));
    XCTAssertEqual(cheatstub::calls, std::vector<std::string>({"reset", "set 0 on OK-1", "set 1 on BAD", "set 2 on OK-2"}));
}

- (void)testApplyingTwiceGivesTheSameState {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    [host applyCheatCodes:@[@"OK-1", @"OK-2"]];
    NSArray *again = [host applyCheatCodes:@[@"OK-1", @"OK-2"]];
    XCTAssertEqualObjects(again, outcomes({SECheatOutcomeApplied, SECheatOutcomeApplied}));
    XCTAssertEqual(cheatstub::held, 2u);
}

- (void)testEmptyListClearsEveryCheat {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    [host applyCheatCodes:@[@"OK-1"]];
    XCTAssertEqualObjects([host applyCheatCodes:@[]], @[]);
    XCTAssertEqual(cheatstub::held, 0u);
    XCTAssertEqual(cheatstub::calls.back(), "reset");
}

- (void)testPerCodeLimitAndMultiCodeStrings {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    cheatstub::calls.clear();
    NSString *tooLong = [@"OK" stringByPaddingToLength:300 withString:@"A" startingAtIndex:0];
    NSString *withinLimit = [@"OK" stringByPaddingToLength:200 withString:@"A" startingAtIndex:0];
    NSArray *result = [host applyCheatCodes:@[@"OK-1+OK-2", tooLong, @"", withinLimit]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeRejected, SECheatOutcomeRejected, SECheatOutcomeRejected, SECheatOutcomeApplied}));
    XCTAssertEqual(cheatstub::calls.size(), 2u);
    XCTAssertTrue(cheatstub::calls[0] == "reset");
    XCTAssertTrue(cheatstub::calls[1] == std::string("set 0 on ") + [withinLimit UTF8String]);
}

- (void)testCoreWithoutCountReportsUnverified {
    SELibretroHost *host = [self stubHost:@"stub_cheat_unverified"];
    XCTAssertEqualObjects([host applyCheatCodes:@[@"OK-1"]], outcomes({SECheatOutcomeUnverified}));
}

- (void)testCoreWithoutCheatsRejectsEverything {
    SELibretroHost *host = [self stubHost:@"stub_no_cheats"];
    XCTAssertFalse(host.supportsCheats);
    XCTAssertEqualObjects([host applyCheatCodes:@[@"OK-1"]], outcomes({SECheatOutcomeRejected}));
    XCTAssertTrue(cheatstub::calls.empty());
}

- (void)testShutdownClearsCheatsBeforeUnloading {
    SELibretroHost *host = [self stubHost:@"stub_cheat"];
    [host applyCheatCodes:@[@"OK-1"]];
    cheatstub::calls.clear();
    [host shutdown];
    XCTAssertEqual(cheatstub::calls, std::vector<std::string>({"reset", "unload"}));
}

- (void)testSnes9xAcceptsGameGenieAndRejectsMalformedCodes {
    SELibretroHost *host = [self realHost:@"snes9x" rom:@"HelloWorld.sfc"];
    if (!host) { XCTSkip(@"HelloWorld.sfc fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);
    NSArray *result = [host applyCheatCodes:@[@"C2C3-CF0D", @"C2C3-CFOD", @"DD32-6DAD", @"RFAA-A6VR"]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeApplied, SECheatOutcomeRejected, SECheatOutcomeApplied, SECheatOutcomeRejected}));
    [host runFrames:5];
    XCTAssertEqualObjects([host applyCheatCodes:@[]], @[]);
    [host runFrames:5];
}

- (void)testGenesisPlusGXAcceptsGameGenieAndRejectsMalformedCodes {
    SELibretroHost *host = [self realHost:@"genesis_plus_gx" rom:@"mega-drive-midi-interface.md"];
    if (!host) { XCTSkip(@"mega-drive-midi-interface.md fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);
    NSArray *result = [host applyCheatCodes:@[@"RFAA-A6VR", @"RFAA-A6V", @"AJBA-AA2A"]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeApplied, SECheatOutcomeRejected, SECheatOutcomeApplied}));
    [host runFrames:5];
    XCTAssertEqualObjects([host applyCheatCodes:@[]], @[]);
    [host runFrames:5];
}

- (void)testPicoDrive32XAcceptsGameGenieAndPARAndRejectsMalformedCodes {
    SELibretroHost *host = [self realHost:@"picodrive" rom:@"noudar.32x"];
    if (!host) { XCTSkip(@"noudar.32x fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);
    NSArray *result = [host applyCheatCodes:@[@"RFAA-A6VR", @"FF0123:0063", @"RFAA-A6V"]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeApplied, SECheatOutcomeApplied, SECheatOutcomeRejected}));
    [host runFrames:5];
    XCTAssertEqualObjects([host applyCheatCodes:@[]], @[]);
    [host runFrames:5];
}

- (void)testGambatteGameBoyCheatsAreUnverifiedAndRun {
    SELibretroHost *host = [self realHost:@"gambatte" rom:@"dmg-acid2.gb"];
    if (!host) { XCTSkip(@"dmg-acid2.gb fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);
    NSArray *result = [host applyCheatCodes:@[@"000-000", @"01001234"]];
    XCTAssertEqualObjects(result, outcomes({SECheatOutcomeUnverified, SECheatOutcomeUnverified}));
    [host runFrames:5];
}

- (void)testMGBAGBACheatsAreUnverifiedAndRun {
    SELibretroHost *host = [self realHost:@"mgba" rom:@"gba-tests-hello.gba"];
    if (!host) { XCTSkip(@"gba-tests-hello.gba fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);
    XCTAssertEqualObjects([host applyCheatCodes:@[@"00000000 00000000"]],
                          outcomes({SECheatOutcomeUnverified}));
    [host runFrames:5];
}

- (void)testMupen64PlusNextCheatWrapperHandlesMultipleLinesAndLimits {
    SELibretroHost *host = [self realHost:@"mupen64plus_next" rom:@"cube-fill-triangle.z64"];
    if (!host) { XCTSkip(@"cube-fill-triangle.z64 fixture missing (scripts/fetch-test-roms.sh)"); }
    XCTAssertTrue(host.supportsCheats);

    NSString *threeLines = @"8009C6E4 03E7 8009C6E6 0001 8009C6E8 0002";
    XCTAssertEqualObjects([host applyCheatCodes:@[threeLines]], outcomes({SECheatOutcomeApplied}));
    [host runFrames:5];

    XCTAssertEqualObjects([host applyCheatCodes:@[@"NOPE"]], outcomes({SECheatOutcomeRejected}));
    [host runFrames:5];

    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (unsigned i = 0; i < 17; i++) {
        [pairs addObject:[NSString stringWithFormat:@"8009C6E4 %04X", i]];
    }
    NSString *limitCode = [[pairs componentsJoinedByString:@" "] stringByPaddingToLength:240 withString:@" " startingAtIndex:0];
    XCTAssertEqual(limitCode.length, 240u);
    XCTAssertEqualObjects([host applyCheatCodes:@[limitCode]], outcomes({SECheatOutcomeApplied}));
    [host runFrames:5];

    XCTAssertEqualObjects([host applyCheatCodes:@[]], @[]);
    [host runFrames:5];
}

@end
