#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include "libretro.h"
#include "SECoreAPI.h"
#include <algorithm>

/// PlayStation (Beetle PSX) disc and BIOS behaviour. Discs are tiny generated cue/bin sets;
/// no commercial disc or Sony BIOS is ever committed. Tests that need a real BIOS look for
/// Tests/Fixtures/local/bios/scph5501.bin (or SUPERSEMU_PSX_BIOS) and skip without it.
@interface SEBeetlePSXTests : XCTestCase
@end

@implementation SEBeetlePSXTests {
    NSString *_fixtures;
    NSURL *_tempDirectory;
}

- (void)setUp {
    _fixtures = NSProcessInfo.processInfo.environment[@"SUPERSEMU_FIXTURES"];
    if (!_fixtures) {
        NSString *here = [NSString stringWithUTF8String:__FILE__];
        _fixtures = [[here.stringByDeletingLastPathComponent stringByDeletingLastPathComponent]
                     stringByAppendingPathComponent:@"Fixtures/local"];
    }
    _tempDirectory = [NSFileManager.defaultManager.temporaryDirectory
                      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_tempDirectory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
}

/// Writes `name`.cue plus a MODE2/2352 data track of `sectors` raw sectors (sync pattern,
/// MSF header, zero payload): a structurally valid image that is not a bootable PS1 disc.
- (NSURL *)syntheticDiscNamed:(NSString *)name sectors:(NSUInteger)sectors writeTrack:(BOOL)writeTrack {
    NSString *bin = [name stringByAppendingString:@".bin"];
    NSString *cue = [NSString stringWithFormat:@"FILE \"%@\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n", bin];
    NSURL *cueURL = [_tempDirectory URLByAppendingPathComponent:[name stringByAppendingString:@".cue"]];
    [cue writeToURL:cueURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (writeTrack) {
        NSMutableData *data = [NSMutableData dataWithLength:sectors * 2352];
        uint8_t *bytes = static_cast<uint8_t *>(data.mutableBytes);
        auto bcd = [](unsigned v) { return uint8_t(((v / 10) << 4) | (v % 10)); };
        for (NSUInteger i = 0; i < sectors; i++) {
            uint8_t *s = bytes + i * 2352;
            memset(s + 1, 0xFF, 10);
            unsigned lba = unsigned(i) + 150;
            s[12] = bcd(lba / 75 / 60);
            s[13] = bcd(lba / 75 % 60);
            s[14] = bcd(lba % 75);
            s[15] = 2;
        }
        [data writeToURL:[_tempDirectory URLByAppendingPathComponent:bin] atomically:YES];
    }
    return cueURL;
}

- (NSURL *)emptySystemDirectory {
    NSURL *system = [_tempDirectory URLByAppendingPathComponent:@"System" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:system withIntermediateDirectories:YES attributes:nil error:nil];
    return system;
}

- (SELibretroHost *)hostForGame:(NSURL *)game system:(NSURL *)system error:(NSError **)error {
    return [[SELibretroHost alloc] initWithCoreID:SECoreIDBeetlePSX romURL:game
                                       saveRAMURL:[_tempDirectory URLByAppendingPathComponent:@"Saves/game.srm"]
                                  systemDirectory:system error:error];
}

- (void)testCoreIsLinkedAndReportsSystemInfo {
    XCTAssertTrue([SELibretroHost.availableCoreIDs containsObject:SECoreIDBeetlePSX]);
    retro_system_info info = {};
    se_core_beetle_psx()->get_system_info(&info);
    XCTAssertEqualObjects(@(se_core_beetle_psx()->identifier), SECoreIDBeetlePSX);
    XCTAssertEqualObjects(@(info.library_name), @"Beetle PSX");
    XCTAssertTrue(info.need_fullpath, @"disc images must be opened by path, not read into memory");
    NSArray *extensions = [@(info.valid_extensions) componentsSeparatedByString:@"|"];
    for (NSString *ext in @[@"cue", @"chd", @"m3u", @"pbp"]) XCTAssertTrue([extensions containsObject:ext], @"%@", ext);
}

/// With no Sony BIOS in the system directory Beetle PSX boots its bundled OpenBIOS. A
/// non-PlayStation disc must not crash the host: it either refuses to load (clean NSError,
/// no active host) or runs frames.
- (void)testSyntheticCueWithoutBIOSDoesNotCrash {
    NSURL *cue = [self syntheticDiscNamed:@"Synthetic Disc" sectors:300 writeTrack:YES];
    NSError *error = nil;
    SELibretroHost *host = [self hostForGame:cue system:[self emptySystemDirectory] error:&error];
    if (host) {
        XCTAssertEqualObjects(host.coreID, SECoreIDBeetlePSX);
        XCTAssertGreaterThan(host.framesPerSecond, 49.0);
        XCTAssertLessThan(host.framesPerSecond, 61.0);
        [host runFrames:120];
        [host shutdown];
    } else {
        XCTAssertNotNil(error);
    }
    XCTAssertNil(SELibretroHost.activeHost);
}

/// need_fullpath cores never read the image in the host, but a missing file is still an error.
- (void)testMissingDiscFileIsAnError {
    NSError *error = nil;
    SELibretroHost *host = [self hostForGame:[_tempDirectory URLByAppendingPathComponent:@"Nope.cue"]
                                      system:[self emptySystemDirectory] error:&error];
    XCTAssertNil(host);
    XCTAssertNotNil(error);
    XCTAssertNil(SELibretroHost.activeHost);
}

- (void)testCueWithMissingTrackFailsCleanly {
    NSURL *cue = [self syntheticDiscNamed:@"Missing Track" sectors:0 writeTrack:NO];
    NSError *error = nil;
    SELibretroHost *host = [self hostForGame:cue system:[self emptySystemDirectory] error:&error];
    XCTAssertNil(host);
    XCTAssertNotNil(error);
    XCTAssertNil(SELibretroHost.activeHost);

    // The core is left reusable: the next launch works.
    NSURL *good = [self syntheticDiscNamed:@"After Failure" sectors:300 writeTrack:YES];
    SELibretroHost *again = [self hostForGame:good system:[self emptySystemDirectory] error:&error];
    if (again) [again runFrames:10];
    [again shutdown];
    XCTAssertNil(SELibretroHost.activeHost);
}

/// Needs a real BIOS (never committed): boots it with the synthetic disc and checks the BIOS
/// draws something (the Sony intro / CD player shell).
- (void)testRealBIOSBootsWithSyntheticDisc {
    NSString *bios = NSProcessInfo.processInfo.environment[@"SUPERSEMU_PSX_BIOS"]
        ?: [_fixtures stringByAppendingPathComponent:@"bios/scph5501.bin"];
    if (![NSFileManager.defaultManager fileExistsAtPath:bios]) {
        XCTSkip(@"No PS1 BIOS at %@ (set SUPERSEMU_PSX_BIOS to run)", bios);
    }
    NSURL *system = [self emptySystemDirectory];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[NSURL fileURLWithPath:bios]
        toURL:[system URLByAppendingPathComponent:@"scph5501.bin"] error:nil]);
    NSURL *cue = [self syntheticDiscNamed:@"BIOS Boot" sectors:300 writeTrack:YES];
    NSError *error = nil;
    SELibretroHost *host = [self hostForGame:cue system:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    [host runFrames:600];
    NSData *frame = host.frameBufferData;
    const uint32_t *pixels = static_cast<const uint32_t *>(frame.bytes);
    NSMutableSet *colors = [NSMutableSet set];
    for (NSUInteger i = 0; i < frame.length / 4; i++) [colors addObject:@(pixels[i])];
    XCTAssertGreaterThan(colors.count, 1u, @"BIOS screen is a single solid colour");
    [host shutdown];
}

/// No Sony BIOS: the bundled OpenBIOS boots, finds no bootable executable on the synthetic
/// disc and runs its shell, which exercises CPU, GTE and the software GPU. Its output and
/// save state must replay identically from a checkpoint.
- (void)testSyntheticDiscRunsFramesOnOpenBIOSDeterministically {
    NSURL *cue = [self syntheticDiscNamed:@"OpenBIOS Boot" sectors:300 writeTrack:YES];
    NSError *error = nil;
    SELibretroHost *host = [self hostForGame:cue system:[self emptySystemDirectory] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:300];
    XCTAssertGreaterThanOrEqual(host.frameWidth, 256);
    XCTAssertGreaterThanOrEqual(host.frameHeight, 224);
    NSData *frame = host.frameBufferData;
    XCTAssertEqual(frame.length, (NSUInteger)host.frameWidth * host.frameHeight * 4);
    const uint32_t *pixels = static_cast<const uint32_t *>(frame.bytes);
    NSMutableSet *colors = [NSMutableSet set];
    uint32_t brightest = 0;
    for (NSUInteger i = 0; i < frame.length / 4; i++) {
        uint32_t p = pixels[i];
        [colors addObject:@(p)];
        brightest = std::max({brightest, (p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF});
    }
    XCTAssertGreaterThan(colors.count, 1u, @"OpenBIOS frame is a single solid colour");
    // 15-bit PS1 colour must be widened to 8-bit channels (unscaled would stay <= 0x1F).
    XCTAssertGreaterThan(brightest, 0x1Fu);

    NSData *checkpoint = [host serializeState];
    XCTAssertGreaterThan(checkpoint.length, 0u);
    [host runFrames:60];
    NSData *afterFirstRun = [host serializeState];
    NSData *frameAfterFirstRun = host.frameBufferData;
    XCTAssertNotEqualObjects(checkpoint, afterFirstRun);
    XCTAssertTrue([host unserializeState:checkpoint]);
    [host runFrames:60];
    XCTAssertEqualObjects(host.frameBufferData, frameAfterFirstRun);
    XCTAssertEqualObjects([host serializeState], afterFirstRun);
    [host shutdown];
}

@end
