#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#import "SELibretroHost+Testing.h"

@interface SELibretroHostTests : XCTestCase
@end

@implementation SELibretroHostTests {
    NSURL *_romURL;
    NSURL *_n64ROMURL;
    NSURL *_tempDirectory;
}

- (void)setUp {
    NSString *fixtures = NSProcessInfo.processInfo.environment[@"SUPERSEMU_FIXTURES"];
    if (!fixtures) {
        NSString *here = [NSString stringWithUTF8String:__FILE__];
        fixtures = [[here.stringByDeletingLastPathComponent stringByDeletingLastPathComponent]
                    stringByAppendingPathComponent:@"Fixtures/local"];
    }
    _romURL = [NSURL fileURLWithPath:[fixtures stringByAppendingPathComponent:@"HelloWorld.sfc"]];
    _n64ROMURL = [NSURL fileURLWithPath:[fixtures stringByAppendingPathComponent:@"cube-fill-triangle.z64"]];
    _tempDirectory = [NSFileManager.defaultManager.temporaryDirectory
                      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    SELibretroHost.pendingCoreOptionOverrides = @{};
    SELibretroHost.logHandler = nil;
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    SELibretroHost.pendingCoreOptionOverrides = @{};
    SELibretroHost.logHandler = nil;
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
}

- (SELibretroHost *)makeHost {
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithROMURL:_romURL
                                                       saveRAMURL:[_tempDirectory URLByAppendingPathComponent:@"Saves/test.srm"]
                                                  systemDirectory:[_tempDirectory URLByAppendingPathComponent:@"System"]
                                                            error:&error];
    XCTAssertNotNil(host, @"%@", error);
    return host;
}

- (SELibretroHost *)makeHostWithCoreID:(NSString *)coreID romURL:(NSURL *)romURL {
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:coreID
                                                          romURL:romURL
                                                      saveRAMURL:[_tempDirectory URLByAppendingPathComponent:@"Saves/test.srm"]
                                                 systemDirectory:[_tempDirectory URLByAppendingPathComponent:@"System"]
                                                           error:&error];
    XCTAssertNotNil(host, @"%@", error);
    return host;
}

- (BOOL)fixtureMissing {
    return ![NSFileManager.defaultManager fileExistsAtPath:_romURL.path];
}

- (BOOL)n64FixtureMissing {
    return ![NSFileManager.defaultManager fileExistsAtPath:_n64ROMURL.path];
}

- (void)testLoadsSnes9xAndReportsTiming {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *host = [self makeHost];
    XCTAssertTrue([host.coreName containsString:@"Snes9x"], @"%@", host.coreName);
    XCTAssertGreaterThan(host.framesPerSecond, 50.0);
    XCTAssertLessThan(host.framesPerSecond, 61.0);
    XCTAssertGreaterThan(host.sampleRate, 0.0);
}

- (void)testRendersNonBlankFrame {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *host = [self makeHost];
    [host runFrames:120];
    XCTAssertEqual(host.frameWidth, 256);
    XCTAssertGreaterThanOrEqual(host.frameHeight, 224);
    NSData *frame = host.frameBufferData;
    const uint32_t *pixels = static_cast<const uint32_t *>(frame.bytes);
    NSMutableSet *colors = [NSMutableSet set];
    for (NSUInteger i = 0; i < frame.length / 4; i++) [colors addObject:@(pixels[i])];
    XCTAssertGreaterThan(colors.count, 1u, @"frame is a single solid colour");
    CGImageRef image = [host copyFrameImage];
    XCTAssertTrue(image != NULL);
    CGImageRelease(image);
}

- (void)testResetClearsInputAndFramesContinue {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *host = [self makeHost];
    [host runFrames:2];
    [host setButtons:SEJoypadButtonA forPort:0];

    [host reset];

    XCTAssertEqual([host buttonsForPort:0], (SEJoypadButtons)0);
    [host runFrames:2];
    XCTAssertGreaterThan(host.frameWidth, 0);
    XCTAssertGreaterThan(host.frameHeight, 0);
    XCTAssertGreaterThan(host.frameBufferData.length, 0u);
}

- (void)testStateRestoreIsDeterministic {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *host = [self makeHost];
    [host runFrames:60];
    NSData *checkpoint = [host serializeState];
    XCTAssertGreaterThan(checkpoint.length, 0u);

    [host runFrames:60];
    NSData *afterFirstRun = [host serializeState];
    NSData *frameAfterFirstRun = host.frameBufferData;
    XCTAssertNotEqualObjects(checkpoint, afterFirstRun, @"emulation did not advance");

    XCTAssertTrue([host unserializeState:checkpoint]);
    [host runFrames:60];
    XCTAssertEqualObjects([host serializeState], afterFirstRun);
    XCTAssertEqualObjects(host.frameBufferData, frameAfterFirstRun);
}

- (void)testStateFileResumesInFreshSession {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    NSURL *stateURL = [_tempDirectory URLByAppendingPathComponent:@"States/auto.state"];
    NSData *expected = nil;
    @autoreleasepool {
        SELibretroHost *first = [self makeHost];
        [first runFrames:90];
        NSError *error = nil;
        XCTAssertTrue([first saveStateToURL:stateURL error:&error], @"%@", error);
        expected = [first serializeState];
        [first shutdown];
    }
    SELibretroHost *second = [self makeHost];
    NSError *error = nil;
    XCTAssertTrue([second loadStateFromURL:stateURL error:&error], @"%@", error);
    XCTAssertEqualObjects([second serializeState], expected);
}

- (void)testOnlyOneHostCanBeActive {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *host = [self makeHost];
    NSError *error = nil;
    SELibretroHost *second = [[SELibretroHost alloc] initWithROMURL:_romURL
                                                         saveRAMURL:[_tempDirectory URLByAppendingPathComponent:@"x.srm"]
                                                    systemDirectory:_tempDirectory
                                                              error:&error];
    XCTAssertNil(second);
    XCTAssertNotNil(error);
    XCTAssertEqual(SELibretroHost.activeHost, host);
}

- (void)testN64OverridesAreAppliedAndUnknownOptionsAreIgnored {
    if ([self n64FixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost.pendingCoreOptionOverrides = @{
        @"mupen64plus-43screensize": @"320x240",
        @"bogus-key": @"x",
    };
    SELibretroHost *host = [self makeHostWithCoreID:SECoreIDMupen64PlusNext romURL:_n64ROMURL];
    [host runFrames:3];
    XCTAssertEqualObjects(host.coreOptions[@"mupen64plus-43screensize"], @"320x240");
    XCTAssertNil(host.coreOptions[@"bogus-key"]);
    XCTAssertEqualObjects(host.coreOptions[@"mupen64plus-cpucore"], @"cached_interpreter");
    XCTAssertEqual(host.frameWidth, 320);

    [host shutdown];
    SELibretroHost.pendingCoreOptionOverrides = @{};
    host = [self makeHostWithCoreID:SECoreIDMupen64PlusNext romURL:_n64ROMURL];
    [host runFrames:3];
    XCTAssertEqual(host.frameWidth, 640);
}

- (void)testRenderPathReportsSoftwareAndIOSurfaceForN64 {
    if ([self fixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *snes = [self makeHost];
    XCTAssertEqualObjects(snes.renderPath, @"software");
    [snes shutdown];

    if ([self n64FixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    SELibretroHost *n64 = [self makeHostWithCoreID:SECoreIDMupen64PlusNext romURL:_n64ROMURL];
    [n64 runFrames:3];
    XCTAssertEqualObjects(n64.renderPath, @"gl-iosurface");
}

- (void)testAudioRingTestingHooksTrackOverflowUnderrunAndBuffering {
    SELibretroHost *host = [self makeHost];
    [host _testResetAudioRing:100];
    [host _testPushSilentAudioFrames:150];
    XCTAssertEqual(host.audioOverflowFrames, 50u);
    XCTAssertEqual(host.audioBufferedFrames, 100);
    [host _testPopAudioFrames:120];
    XCTAssertEqual(host.audioUnderrunFrames, 20u);
    XCTAssertEqual(host.audioBufferedFrames, 0);
    [host _testResetAudioRing:100];
    XCTAssertEqual(host.audioOverflowFrames, 0u);
    XCTAssertEqual(host.audioUnderrunFrames, 0u);
}

- (void)testLogHandlerReceivesN64CoreMessagesDuringLoad {
    if ([self n64FixtureMissing]) { XCTSkip(@"Run scripts/fetch-test-roms.sh first"); }
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    SELibretroHost.logHandler = ^(NSInteger level, NSString *message) {
        [messages addObject:message];
    };
    SELibretroHost *host = [self makeHostWithCoreID:SECoreIDMupen64PlusNext romURL:_n64ROMURL];
    [host runFrames:3];
    XCTAssertGreaterThan(messages.count, 0u);
}

@end
