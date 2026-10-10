#import <XCTest/XCTest.h>
#import "SELibretroHost.h"

@interface SELibretroHostTests : XCTestCase
@end

@implementation SELibretroHostTests {
    NSURL *_romURL;
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
    _tempDirectory = [NSFileManager.defaultManager.temporaryDirectory
                      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
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

- (BOOL)fixtureMissing {
    return ![NSFileManager.defaultManager fileExistsAtPath:_romURL.path];
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

@end
