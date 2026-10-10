#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include <algorithm>

/// Per-core checks for every statically linked libretro core: loads, renders a non-blank
/// frame, deterministic state round trip, and reports id/version for save metadata.
/// ROMs come from scripts/fetch-test-roms.sh; a missing ROM skips its tests.
@interface SECoreMatrixTests : XCTestCase
@end

struct CoreFixture {
    NSString *coreID;
    NSString *rom;
    NSString *nameFragment;
    unsigned minWidth;
    unsigned minHeight;
    /// Reason the core's save state is known not to replay byte-identically, or nil.
    NSString *stateGap;
};

@implementation SECoreMatrixTests {
    NSString *_fixtures;
    NSURL *_tempDirectory;
}

static const CoreFixture kFixtures[] = {
    {@"snes9x", @"HelloWorld.sfc", @"Snes9x", 256, 224},
    {@"gambatte", @"dmg-acid2.gb", @"Gambatte", 160, 144},
    {@"gambatte", @"cgb-acid2.gbc", @"Gambatte", 160, 144},
    {@"mgba", @"gba-tests-hello.gba", @"mGBA", 240, 160},
    // Upstream state format omits the YM2612 busy timer (fm_cycles_busy in core/sound/sound.c),
    // so a ROM that polls the FM chip can diverge by a few bytes after a restore.
    {@"genesis_plus_gx", @"mega-drive-midi-interface.md", @"Genesis Plus GX", 256, 192,
     @"Genesis Plus GX does not save the YM2612 busy timer"},
    // Restores replay the same frames, but PicoDrive's YM2612 chunk (CHUNK_FMv3) drifts by a few
    // bytes (eg_cnt/eg_timer and per-channel FM fields) after a restore.
    {@"picodrive", @"noudar.32x", @"PicoDrive", 320, 224,
     @"PicoDrive's YM2612 state does not replay byte-identically"},
};

- (void)setUp {
    _fixtures = NSProcessInfo.processInfo.environment[@"SUPERSEMU_FIXTURES"];
    if (!_fixtures) {
        NSString *here = [NSString stringWithUTF8String:__FILE__];
        _fixtures = [[here.stringByDeletingLastPathComponent stringByDeletingLastPathComponent]
                     stringByAppendingPathComponent:@"Fixtures/local"];
    }
    _tempDirectory = [NSFileManager.defaultManager.temporaryDirectory
                      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
}

static NSString *describeDifference(NSData *a, NSData *b) {
    if (a.length != b.length) return [NSString stringWithFormat:@"length %lu vs %lu", (unsigned long)a.length, (unsigned long)b.length];
    const uint8_t *x = static_cast<const uint8_t *>(a.bytes), *y = static_cast<const uint8_t *>(b.bytes);
    NSUInteger first = NSNotFound, count = 0;
    for (NSUInteger i = 0; i < a.length; i++) if (x[i] != y[i]) { if (first == NSNotFound) first = i; count++; }
    return first == NSNotFound ? @"identical" : [NSString stringWithFormat:@"%lu bytes differ, first at offset %lu", (unsigned long)count, (unsigned long)first];
}

- (NSURL *)romURL:(const CoreFixture &)fixture {
    return [NSURL fileURLWithPath:[_fixtures stringByAppendingPathComponent:fixture.rom]];
}

- (SELibretroHost *)hostFor:(const CoreFixture &)fixture {
    NSURL *rom = [self romURL:fixture];
    if (![NSFileManager.defaultManager fileExistsAtPath:rom.path]) return nil;
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc]
        initWithCoreID:fixture.coreID romURL:rom
            saveRAMURL:[_tempDirectory URLByAppendingPathComponent:[fixture.rom stringByAppendingString:@".srm"]]
       systemDirectory:[_tempDirectory URLByAppendingPathComponent:@"System"]
                 error:&error];
    XCTAssertNotNil(host, @"%@: %@", fixture.rom, error);
    return host;
}

- (void)forEachFixture:(void (^)(const CoreFixture &fixture, SELibretroHost *host))body {
    NSUInteger ran = 0;
    for (const CoreFixture &fixture : kFixtures) {
        @autoreleasepool {
            SELibretroHost *host = [self hostFor:fixture];
            if (!host) continue;
            body(fixture, host);
            [host shutdown];
            ran++;
        }
    }
    if (ran == 0) XCTSkip(@"Run scripts/fetch-test-roms.sh first");
}

- (void)testAllCoresAreLinked {
    NSArray *expected = @[SECoreIDSnes9x, SECoreIDGambatte, SECoreIDMGBA, SECoreIDGenesisPlusGX,
                          SECoreIDPicoDrive, SECoreIDBeetlePSX];
    XCTAssertEqualObjects(SELibretroHost.availableCoreIDs, expected);
}

- (void)testUnknownCoreIsAnError {
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:@"nope"
                                                           romURL:[NSURL fileURLWithPath:@"/dev/null"]
                                                       saveRAMURL:[_tempDirectory URLByAppendingPathComponent:@"x.srm"]
                                                  systemDirectory:_tempDirectory
                                                            error:&error];
    XCTAssertNil(host);
    XCTAssertNotNil(error);
    XCTAssertNil(SELibretroHost.activeHost);
}

- (void)testEachCoreLoadsAndReportsMetadata {
    [self forEachFixture:^(const CoreFixture &fixture, SELibretroHost *host) {
        XCTAssertEqualObjects(host.coreID, fixture.coreID);
        XCTAssertTrue([host.coreName containsString:fixture.nameFragment], @"%@", host.coreName);
        XCTAssertGreaterThan(host.coreRevision.length, 0u);
        XCTAssertTrue([host.coreVersion containsString:host.coreRevision], @"%@", host.coreVersion);
        XCTAssertGreaterThan(host.framesPerSecond, 49.0, @"%@", fixture.rom);
        XCTAssertLessThan(host.framesPerSecond, 61.0, @"%@", fixture.rom);
        XCTAssertGreaterThan(host.sampleRate, 0.0, @"%@", fixture.rom);
    }];
}

- (void)testEachCoreRendersNonBlankFrame {
    [self forEachFixture:^(const CoreFixture &fixture, SELibretroHost *host) {
        [host runFrames:180];
        XCTAssertGreaterThanOrEqual(host.frameWidth, fixture.minWidth, @"%@", fixture.rom);
        XCTAssertGreaterThanOrEqual(host.frameHeight, fixture.minHeight, @"%@", fixture.rom);
        NSData *frame = host.frameBufferData;
        XCTAssertEqual(frame.length, (NSUInteger)host.frameWidth * host.frameHeight * 4, @"%@", fixture.rom);
        const uint32_t *pixels = static_cast<const uint32_t *>(frame.bytes);
        NSMutableSet *colors = [NSMutableSet set];
        uint32_t brightest = 0;
        for (NSUInteger i = 0; i < frame.length / 4; i++) {
            [colors addObject:@(pixels[i])];
            uint32_t p = pixels[i];
            brightest = std::max({brightest, (p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF});
        }
        XCTAssertGreaterThan(colors.count, 1u, @"%@ frame is a single solid colour", fixture.rom);
        // Catches cores whose pixel format is mis-scaled (e.g. 5-bit channels in XRGB8888).
        XCTAssertGreaterThanOrEqual(brightest, 0xC0u, @"%@ frame is implausibly dark", fixture.rom);
        CGImageRef image = [host copyFrameImage];
        XCTAssertTrue(image != NULL, @"%@", fixture.rom);
        CGImageRelease(image);
    }];
}

- (void)testEachCoreStateRoundTripIsDeterministic {
    [self forEachFixture:^(const CoreFixture &fixture, SELibretroHost *host) {
        [host runFrames:60];
        NSData *checkpoint = [host serializeState];
        XCTAssertGreaterThan(checkpoint.length, 0u, @"%@", fixture.rom);

        [host runFrames:60];
        NSData *afterFirstRun = [host serializeState];
        NSData *frameAfterFirstRun = host.frameBufferData;
        XCTAssertNotEqualObjects(checkpoint, afterFirstRun, @"%@ did not advance", fixture.rom);

        XCTAssertTrue([host unserializeState:checkpoint], @"%@", fixture.rom);
        [host runFrames:60];
        NSData *replayed = [host serializeState];
        XCTAssertEqualObjects(host.frameBufferData, frameAfterFirstRun, @"%@", fixture.rom);
        void (^compareState)(void) = ^{
            XCTAssertEqualObjects(replayed, afterFirstRun, @"%@: %@", fixture.rom,
                                  describeDifference(replayed, afterFirstRun));
        };
        if (fixture.stateGap) {
            XCTExpectFailureWithOptionsInBlock(fixture.stateGap, XCTExpectedFailureOptions.nonStrictOptions, compareState);
        } else {
            compareState();
        }
    }];
}

/// A state file written by one session resumes identically in a new one: after loading it
/// and running on, state and frame match the original session's continuation.
- (void)testEachCoreStateFileResumesInFreshSession {
    for (const CoreFixture &fixture : kFixtures) {
        NSURL *stateURL = [_tempDirectory URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"States/%@.state", fixture.rom]];
        NSData *expectedState = nil, *expectedFrame = nil;
        @autoreleasepool {
            SELibretroHost *first = [self hostFor:fixture];
            if (!first) continue;
            [first runFrames:90];
            NSError *error = nil;
            XCTAssertTrue([first saveStateToURL:stateURL error:&error], @"%@: %@", fixture.rom, error);
            [first runFrames:30];
            expectedState = [first serializeState];
            expectedFrame = first.frameBufferData;
            [first shutdown];
        }
        @autoreleasepool {
            SELibretroHost *second = [self hostFor:fixture];
            NSError *error = nil;
            XCTAssertTrue([second loadStateFromURL:stateURL error:&error], @"%@: %@", fixture.rom, error);
            [second runFrames:30];
            NSData *resumed = [second serializeState];
            XCTAssertEqualObjects(second.frameBufferData, expectedFrame, @"%@", fixture.rom);
            void (^compareState)(void) = ^{
                XCTAssertEqualObjects(resumed, expectedState, @"%@: %@", fixture.rom,
                                      describeDifference(resumed, expectedState));
            };
            if (fixture.stateGap) {
                XCTExpectFailureWithOptionsInBlock(fixture.stateGap, XCTExpectedFailureOptions.nonStrictOptions, compareState);
            } else {
                compareState();
            }
            [second shutdown];
        }
    }
}

@end
