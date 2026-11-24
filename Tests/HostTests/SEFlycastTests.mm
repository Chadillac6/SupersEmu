#import <XCTest/XCTest.h>
#import "SELibretroHost.h"

/// Dreamcast (Flycast) behaviour with freely licensed homebrew from scripts/fetch-test-roms.sh.
/// No Sega BIOS is used: every test runs on Flycast's HLE BIOS, so only homebrew is covered.
@interface SEFlycastTests : XCTestCase
@end

@implementation SEFlycastTests {
    NSString *_fixtures;
    NSURL *_tempDirectory;
}

static const NSUInteger kVMUSize = 128 * 1024;

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

- (NSURL *)fixture:(NSString *)name {
    NSURL *url = [NSURL fileURLWithPath:[_fixtures stringByAppendingPathComponent:name]];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;
    return url;
}

- (NSURL *)saveRAMURL {
    return [_tempDirectory URLByAppendingPathComponent:@"Saves/game.srm"];
}

- (SELibretroHost *)hostForURL:(NSURL *)rom {
    NSError *error = nil;
    SELibretroHost *host = [[SELibretroHost alloc] initWithCoreID:SECoreIDFlycast romURL:rom
                                                       saveRAMURL:[self saveRAMURL]
                                                  systemDirectory:[_tempDirectory URLByAppendingPathComponent:@"System"]
                                                            error:&error];
    XCTAssertNotNil(host, @"%@: %@", rom.lastPathComponent, error);
    return host;
}

static NSUInteger distinctColors(NSData *frame) {
    const uint32_t *pixels = static_cast<const uint32_t *>(frame.bytes);
    NSMutableSet *colors = [NSMutableSet set];
    for (NSUInteger i = 0; i < frame.length / 4 && colors.count < 16; i += 7) [colors addObject:@(pixels[i] & 0xFFFFFF)];
    return colors.count;
}

- (void)assertRendersPicture:(NSString *)name {
    NSURL *rom = [self fixture:name];
    if (!rom) XCTSkip(@"%@ fixture missing (scripts/fetch-test-roms.sh)", name);
    SELibretroHost *host = [self hostForURL:rom];
    XCTAssertTrue([host.coreName containsString:@"Flycast"], @"%@", host.coreName);
    XCTAssertTrue([host.renderPath hasPrefix:@"gl"], @"%@", host.renderPath);
    [host runFrames:600];
    XCTAssertGreaterThanOrEqual(host.frameWidth, 320);
    XCTAssertGreaterThanOrEqual(host.frameHeight, 240);
    XCTAssertGreaterThan(distinctColors(host.frameBufferData), 1u, @"%@ frame is a single solid colour", name);
}

- (void)testElfBootsOnHLEBIOSAndRendersPicture {
    [self assertRendersPicture:@"chroma-circuit.elf"];
}

- (void)testDiscImageBootsOnHLEBIOSAndRendersPicture {
    [self assertRendersPicture:@"chroma-circuit.cdi"];
}

/// VMU A1 is the save RAM: a fresh card is formatted, flushes to the .srm, and an edited .srm
/// is what the next session sees.
- (void)testVMUIsSaveRAMAndPersistsAcrossSessions {
    NSURL *rom = [self fixture:@"chroma-circuit.elf"];
    if (!rom) XCTSkip(@"chroma-circuit.elf fixture missing (scripts/fetch-test-roms.sh)");
    NSMutableData *card = nil;
    @autoreleasepool {
        SELibretroHost *host = [self hostForURL:rom];
        [host runFrames:30];
        XCTAssertTrue([host flushSaveRAMWithError:nil]);
        [host shutdown];
        card = [NSMutableData dataWithContentsOfURL:[self saveRAMURL]];
        XCTAssertEqual(card.length, kVMUSize);
    }
    const uint8_t *bytes = static_cast<const uint8_t *>(card.bytes);
    BOOL formatted = NO;
    for (NSUInteger i = 0; i < card.length && !formatted; i++) formatted = bytes[i] != 0;
    XCTAssertTrue(formatted, @"a new VMU should be formatted");

    // Block 10 is in the user data area, which the root block marks free on a fresh card.
    const char marker[] = "SupersEmu VMU marker";
    [card replaceBytesInRange:NSMakeRange(10 * 512, sizeof(marker)) withBytes:marker];
    XCTAssertTrue([card writeToURL:[self saveRAMURL] atomically:YES]);
    @autoreleasepool {
        SELibretroHost *host = [self hostForURL:rom];
        [host runFrames:30];
        XCTAssertTrue([host flushSaveRAMWithError:nil]);
        [host shutdown];
    }
    NSData *reloaded = [NSData dataWithContentsOfURL:[self saveRAMURL]];
    XCTAssertEqualObjects([reloaded subdataWithRange:NSMakeRange(10 * 512, sizeof(marker))],
                          [NSData dataWithBytes:marker length:sizeof(marker)]);
}

- (void)testPlaylistExposesEveryDisc {
    NSURL *disc = [self fixture:@"chroma-circuit.cdi"];
    if (!disc) XCTSkip(@"chroma-circuit.cdi fixture missing (scripts/fetch-test-roms.sh)");
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in @[@"Disc 1.cdi", @"Disc 2.cdi"]) {
        XCTAssertTrue([fm copyItemAtURL:disc toURL:[_tempDirectory URLByAppendingPathComponent:name] error:nil]);
    }
    NSURL *playlist = [_tempDirectory URLByAppendingPathComponent:@"Game.m3u"];
    XCTAssertTrue([@"Disc 1.cdi\nDisc 2.cdi\n" writeToURL:playlist atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    SELibretroHost *host = [self hostForURL:playlist];
    [host runFrames:60];
    XCTAssertEqual(host.diskCount, 2);
    XCTAssertEqual(host.currentDisk, 0);
    NSError *error = nil;
    XCTAssertTrue([host insertDisk:1 error:&error], @"%@", error);
    XCTAssertEqual(host.currentDisk, 1);
}

@end
