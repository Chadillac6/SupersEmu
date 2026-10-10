#import <XCTest/XCTest.h>
#import "SELibretroHost.h"

/// Sega CD (Genesis Plus GX) and 32X (PicoDrive) checks that need no downloaded content:
/// every disc, ROM and BIOS here is synthetic and generated into a temp directory.
@interface SESegaDiscCoreTests : XCTestCase
@end

@implementation SESegaDiscCoreTests {
    NSURL *_dir;
}

- (void)setUp {
    _dir = [NSFileManager.defaultManager.temporaryDirectory
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[_dir URLByAppendingPathComponent:@"System"]
                           withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    [NSFileManager.defaultManager removeItemAtURL:_dir error:nil];
}

- (NSURL *)url:(NSString *)name { return [_dir URLByAppendingPathComponent:name]; }
- (NSURL *)systemDirectory { return [self url:@"System"]; }

/// A one-track MODE1/2048 disc whose first sector carries the Sega CD system ID, so
/// Genesis Plus GX's cdd_load() recognises it as a Mega CD disc. No boot code.
- (NSURL *)writeSyntheticSegaCDDisc {
    NSMutableData *track = [NSMutableData dataWithLength:2048 * 300];
    memcpy(track.mutableBytes, "SEGADISCSYSTEM  ", 16);
    memcpy(static_cast<char *>(track.mutableBytes) + 0x100, "SEGA MEGA DRIVE ", 16);
    memcpy(static_cast<char *>(track.mutableBytes) + 0x1F0, "U", 1);
    [track writeToURL:[self url:@"synthetic.iso"] atomically:YES];
    NSString *cue = @"FILE \"synthetic.iso\" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n";
    [cue writeToURL:[self url:@"synthetic.cue"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [self url:@"synthetic.cue"];
}

- (SELibretroHost *)openCore:(NSString *)coreID rom:(NSURL *)rom error:(NSError **)error {
    return [[SELibretroHost alloc] initWithCoreID:coreID romURL:rom
                                       saveRAMURL:[self url:@"Saves/game.srm"]
                                  systemDirectory:self.systemDirectory error:error];
}

- (void)testSegaCDWithoutBIOSFailsCleanly {
    NSURL *cue = [self writeSyntheticSegaCDDisc];
    NSError *error = nil;
    SELibretroHost *host = [self openCore:SECoreIDGenesisPlusGX rom:cue error:&error];
    XCTAssertNil(host);
    XCTAssertNotNil(error);
    XCTAssertNil(SELibretroHost.activeHost);
    // The failed load released the core, so a second attempt fails the same way (not "already running").
    XCTAssertNil([self openCore:SECoreIDGenesisPlusGX rom:cue error:nil]);
}

- (void)testSegaCDCueWithMissingTrackFailsCleanly {
    NSString *cue = @"FILE \"missing.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n";
    [cue writeToURL:[self url:@"broken.cue"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    XCTAssertNil([self openCore:SECoreIDGenesisPlusGX rom:[self url:@"broken.cue"] error:&error]);
    XCTAssertNotNil(error);
    XCTAssertNil(SELibretroHost.activeHost);
}

/// With a (blank, synthetic) BIOS in the system directory under its canonical names the
/// synthetic cue boots the Sega CD hardware: proves cue parsing, disc detection and the
/// system-directory BIOS lookup. A blank BIOS can't boot the disc, so no frame content check.
- (void)testSegaCDCueLoadsWithBIOSInSystemDirectory {
    NSURL *cue = [self writeSyntheticSegaCDDisc];
    NSData *blankBIOS = [NSMutableData dataWithLength:128 * 1024];
    for (NSString *name in @[@"bios_CD_U.bin", @"bios_CD_E.bin", @"bios_CD_J.bin"])
        [blankBIOS writeToURL:[self.systemDirectory URLByAppendingPathComponent:name] atomically:YES];
    NSError *error = nil;
    SELibretroHost *host = [self openCore:SECoreIDGenesisPlusGX rom:cue error:&error];
    XCTAssertNotNil(host, @"%@", error);
    XCTAssertTrue([host.coreName containsString:@"Genesis Plus GX"], @"%@", host.coreName);
    [host runFrames:30];
    XCTAssertGreaterThan(host.frameWidth, 0u);
    XCTAssertGreaterThan([host serializeState].length, 0u);
    [host shutdown];
}

/// Minimal Mega Drive header (68000 vectors pointing at a BRA-to-self loop) with a .32x
/// extension: PicoDrive loads it, reports metadata and runs frames.
- (void)testPicoDriveRunsSyntheticROM {
    NSMutableData *rom = [NSMutableData dataWithLength:128 * 1024];
    uint8_t *b = static_cast<uint8_t *>(rom.mutableBytes);
    const uint8_t vectors[] = {0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x02, 0x00}; // SSP, PC=0x200
    memcpy(b, vectors, sizeof vectors);
    memcpy(b + 0x100, "SEGA 32X        ", 16);
    memcpy(b + 0x120, "SUPERSEMU SYNTHETIC 32X TEST", 28);
    memcpy(b + 0x1F0, "JUE", 3);
    b[0x200] = 0x60; b[0x201] = 0xFE; // BRA.S *
    [rom writeToURL:[self url:@"synthetic.32x"] atomically:YES];

    NSError *error = nil;
    SELibretroHost *host = [self openCore:SECoreIDPicoDrive rom:[self url:@"synthetic.32x"] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    XCTAssertEqualObjects(host.coreID, SECoreIDPicoDrive);
    XCTAssertTrue([host.coreName containsString:@"PicoDrive"], @"%@", host.coreName);
    XCTAssertTrue([host.coreVersion containsString:host.coreRevision], @"%@", host.coreVersion);
    XCTAssertGreaterThan(host.framesPerSecond, 49.0);
    XCTAssertLessThan(host.framesPerSecond, 61.0);
    XCTAssertGreaterThan(host.sampleRate, 0.0);
    [host runFrames:60];
    XCTAssertGreaterThanOrEqual(host.frameWidth, 256u);
    XCTAssertGreaterThanOrEqual(host.frameHeight, 224u);
    NSData *state = [host serializeState];
    XCTAssertGreaterThan(state.length, 0u);
    XCTAssertTrue([host unserializeState:state]);
    [host shutdown];
}

@end
