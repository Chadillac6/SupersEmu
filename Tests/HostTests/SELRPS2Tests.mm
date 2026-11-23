#import <XCTest/XCTest.h>
#import "SELibretroHost.h"
#include <TargetConditionals.h>
#include <vector>

#if TARGET_OS_OSX && defined(__aarch64__)
#include <unistd.h>
#include "libretro.h"
#include "SECoreAPI.h"

// Host/CoreEntry/lrps2/se_memcard.c: what the SIO does when a game saves to memory card 1.
extern "C" bool se_core_lrps2_write_card(unsigned address, const void *data, int size);
extern "C" void se_core_lrps2_set_cards_open(bool open);

/// PlayStation 2 (LRPS2, macOS on Apple Silicon). No Sony BIOS or commercial disc is ever used:
/// the boot tests generate a synthetic 4 MB BIOS image (RESET/ROMDIR/ROMVER entries that pass the
/// core's BIOS scan, and a tiny MIPS reset program that turns on the display and draws a sprite
/// through GIF DMA), the same technique as LRPS2's own tests/swdraw. A real BIOS and game boot
/// is not covered here.
@interface SELRPS2Tests : XCTestCase
@end

namespace {

void put32(std::vector<uint8_t> &rom, unsigned at, uint32_t v) {
    rom[at] = uint8_t(v); rom[at + 1] = uint8_t(v >> 8); rom[at + 2] = uint8_t(v >> 16); rom[at + 3] = uint8_t(v >> 24);
}

// MIPS encodings (t0..t7 = 8..15).
uint32_t LUI(unsigned rt, unsigned imm) { return 0x3C000000u | (rt << 16) | (imm & 0xFFFFu); }
uint32_t ORI(unsigned rt, unsigned rs, unsigned imm) { return 0x34000000u | (rs << 21) | (rt << 16) | (imm & 0xFFFFu); }
uint32_t ADDIU(unsigned rt, unsigned rs, int imm) { return 0x24000000u | (rs << 21) | (rt << 16) | (unsigned(imm) & 0xFFFFu); }
uint32_t DSLL32(unsigned rd, unsigned rt) { return 0x0000003Cu | (rt << 16) | (rd << 11); }
uint32_t OR(unsigned rd, unsigned rs, unsigned rt) { return 0x00000025u | (rs << 21) | (rt << 16) | (rd << 11); }
uint32_t SD(unsigned rt, unsigned off, unsigned base) { return 0xFC000000u | (base << 21) | (rt << 16) | (off & 0xFFFFu); }
uint32_t SW(unsigned rt, unsigned off, unsigned base) { return 0xAC000000u | (base << 21) | (rt << 16) | (off & 0xFFFFu); }
uint32_t LW(unsigned rt, unsigned off, unsigned base) { return 0x8C000000u | (base << 21) | (rt << 16) | (off & 0xFFFFu); }
uint32_t ANDI(unsigned rt, unsigned rs, unsigned imm) { return 0x30000000u | (rs << 21) | (rt << 16) | (imm & 0xFFFFu); }
uint32_t BNE(unsigned rs, unsigned rt, int off) { return 0x14000000u | (rs << 21) | (rt << 16) | (unsigned(off) & 0xFFFFu); }
uint32_t B(int off) { return 0x10000000u | (unsigned(off) & 0xFFFFu); }

struct Emitter {
    std::vector<uint8_t> &rom;
    unsigned pc = 0;
    void op(uint32_t v) { put32(rom, pc, v); pc += 4; }
    // t1 = hi:lo, stored as a doubleword at base + off.
    void store64(unsigned base, unsigned off, uint32_t hi, uint32_t lo) {
        op(LUI(9, hi >> 16)); op(ORI(9, 9, hi)); op(DSLL32(9, 9));
        op(LUI(10, lo >> 16)); op(ORI(10, 10, lo)); op(OR(9, 9, 10)); op(SD(9, off, base));
    }
    int back(unsigned target) const { return int(target - (pc + 4)) >> 2; }
};

uint64_t XY(unsigned x, unsigned y) { return uint64_t(x * 16) | (uint64_t(y * 16) << 16); }

/// 4 MB image LRPS2 accepts as a BIOS. Its reset program, also returned in `program` to run as
/// a homebrew ELF, displays a 640x448 frame holding one solid `rgba` rectangle.
NSData *SyntheticBIOS(uint32_t rgba, std::vector<uint8_t> &program) {
    std::vector<uint8_t> rom(4 * 1024 * 1024, 0);
    const unsigned packetAt = 0x2000;
    // GIFtag (PACKED, A+D) followed by (data, register) quadwords.
    const std::pair<unsigned, uint64_t> ad[] = {
        {0x1A, 1},                                        // PRMODECONT
        {0x4C, 10ull << 16},                              // FRAME_1: FBP 0, FBW 10, PSMCT32
        {0x4E, 1ull << 32},                               // ZBUF_1: ZMSK
        {0x47, (1ull << 16) | (1ull << 17)},              // TEST_1: ZTE, ZTST always
        {0x18, 0},                                        // XYOFFSET_1
        {0x40, (639ull << 16) | (447ull << 48)},          // SCISSOR_1: 0..639, 0..447
        {0x01, uint64_t(rgba) | (0x3f800000ull << 32)},   // RGBAQ
        {0x00, 4},                                        // PRIM: triangle strip
        {0x05, XY(64, 64)},                               // XYZ2
        {0x05, XY(576, 64)},                              // XYZ2
        {0x05, XY(64, 384)},                              // XYZ2
        {0x05, XY(576, 384)},                             // XYZ2
    };
    const unsigned count = sizeof(ad) / sizeof(ad[0]);
    unsigned q = packetAt;
    put32(rom, q, count | 0x8000u); put32(rom, q + 4, 0x10000000u); put32(rom, q + 8, 0xEu); q += 16;
    for (const auto &[reg, data] : ad) {
        put32(rom, q, uint32_t(data)); put32(rom, q + 4, uint32_t(data >> 32)); put32(rom, q + 8, reg); q += 16;
    }
    const unsigned qwc = count + 1;

    std::vector<uint8_t> code(0x1000, 0);
    Emitter e{code};
    e.op(LUI(8, 0xB200));                                         // t0 = GS privileged registers
    e.store64(8, 0x00, 0, 0xFF25u);                               // PMODE: read circuit 1
    e.store64(8, 0x10, 0x7, 0x40834504u);                         // SMODE1 (NTSC, as a BIOS sets it)
    e.store64(8, 0x20, 0, 1);                                     // SMODE2: interlaced
    e.store64(8, 0x70, 0, 10u << 9);                              // DISPFB1: FBW 10, PSMCT32
    e.store64(8, 0x80, 2559u | (447u << 12), 636u | (50u << 12) | (3u << 23)); // DISPLAY1
    e.op(LUI(11, 0xBFC0)); e.op(ORI(11, 11, packetAt));          // t3 = packet in ROM
    e.op(LUI(12, 0xA020));                                        // t4 = RAM 0x200000, uncached
    e.op(ORI(14, 0, qwc * 4));                                    // t6 = words
    unsigned loop = e.pc;
    e.op(LW(9, 0, 11)); e.op(SW(9, 0, 12)); e.op(ADDIU(11, 11, 4)); e.op(ADDIU(12, 12, 4)); e.op(ADDIU(14, 14, -1));
    e.op(BNE(14, 0, e.back(loop))); e.op(0);
    e.op(LUI(10, 0xB000)); e.op(ORI(10, 10, 0xE000)); e.op(ORI(9, 0, 1)); e.op(SW(9, 0, 10)); // D_CTRL.DMAE
    e.op(LUI(13, 0xB000)); e.op(ORI(13, 13, 0xA000));             // t5 = GIF DMA channel
    e.op(LUI(12, 0x0020)); e.op(SW(12, 0x10, 13));                // MADR
    e.op(ORI(14, 0, qwc)); e.op(SW(14, 0x20, 13));                // QWC
    e.op(ORI(15, 0, 0x101)); e.op(SW(15, 0x00, 13));              // CHCR: DIR | STR
    loop = e.pc;
    e.op(LW(9, 0, 13)); e.op(0); e.op(ANDI(9, 9, 0x100)); e.op(BNE(9, 0, e.back(loop))); e.op(0);
    e.op(B(-1)); e.op(0);                                         // spin
    program.assign(code.begin(), code.begin() + e.pc);
    memcpy(rom.data(), program.data(), program.size());
    memcpy(&rom[0x1000], "RESET", 5);  put32(rom, 0x1000 + 12, 0x1000);
    memcpy(&rom[0x1010], "ROMDIR", 6); put32(rom, 0x1010 + 12, 0x40);
    memcpy(&rom[0x1020], "ROMVER", 6); put32(rom, 0x1020 + 12, 0x10);
    memcpy(&rom[0x1040], "0160AC20020207", 14);
    return [NSData dataWithBytes:rom.data() length:rom.size()];
}

/// A minimal MIPS ELF: one PT_LOAD at 0x100000 holding `program`.
NSData *TinyELF(const std::vector<uint8_t> &program) {
    std::vector<uint8_t> f(0x60 + program.size(), 0);
    const uint8_t ident[] = {0x7F, 'E', 'L', 'F', 1, 1, 1};
    memcpy(f.data(), ident, sizeof(ident));
    auto put16 = [&](unsigned at, uint16_t v) { f[at] = uint8_t(v); f[at + 1] = uint8_t(v >> 8); };
    put16(16, 2); put16(18, 8); put32(f, 20, 1);                  // ET_EXEC, EM_MIPS, version
    put32(f, 24, 0x00100000);                                     // entry
    put32(f, 28, 52); put16(40, 52); put16(42, 32); put16(44, 1); // phoff, ehsize, phentsize, phnum
    put32(f, 52, 1); put32(f, 56, 0x60); put32(f, 60, 0x00100000); put32(f, 64, 0x00100000);
    put32(f, 68, uint32_t(program.size())); put32(f, 72, uint32_t(program.size()));
    put32(f, 76, 5); put32(f, 80, 0x10);                          // PT_LOAD, R+X
    memcpy(&f[0x60], program.data(), program.size());
    return [NSData dataWithBytes:f.data() length:f.size()];
}

} // namespace

@implementation SELRPS2Tests {
    NSURL *_tempDirectory;
    NSMutableArray<NSString *> *_log;
    std::vector<uint8_t> _program;
}

- (void)setUp {
    _tempDirectory = [NSFileManager.defaultManager.temporaryDirectory
                      URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_tempDirectory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    // Fast boot skips straight to the content; the synthetic BIOS never hands over to it.
    SELibretroHost.pendingCoreOptionOverrides = @{@"pcsx2_fastboot": @"disabled"};
    _log = [NSMutableArray array];
    NSMutableArray<NSString *> *log = _log;
    SELibretroHost.logHandler = ^(NSInteger level, NSString *message) {
        @synchronized (log) { [log addObject:message]; }
    };
}

- (void)tearDown {
    [SELibretroHost.activeHost shutdown];
    SELibretroHost.logHandler = nil;
    SELibretroHost.pendingCoreOptionOverrides = @{};
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
}

- (NSURL *)systemDirectoryWithBIOS:(BOOL)withBIOS {
    NSURL *system = [_tempDirectory URLByAppendingPathComponent:@"System" isDirectory:YES];
    NSURL *bios = [system URLByAppendingPathComponent:@"pcsx2/bios" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:bios withIntermediateDirectories:YES attributes:nil error:nil];
    if (withBIOS) {
        [SyntheticBIOS(0x80FF8040u, _program) writeToURL:[bios URLByAppendingPathComponent:@"se_synthetic.bin"] atomically:YES];
    }
    return system;
}

- (NSURL *)game { return [self gameInFolder:nil]; }

- (NSURL *)gameInFolder:(NSString *)folder {
    NSURL *directory = folder ? [_tempDirectory URLByAppendingPathComponent:folder isDirectory:YES] : _tempDirectory;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [directory URLByAppendingPathComponent:@"Homebrew Test.elf"];
    if (_program.empty()) SyntheticBIOS(0x80FF8040u, _program);
    [TinyELF(_program) writeToURL:url atomically:YES];
    return url;
}

- (NSURL *)saveDirectory { return [_tempDirectory URLByAppendingPathComponent:@"Saves" isDirectory:YES]; }

- (NSURL *)workingDirectory { return [self.saveDirectory URLByAppendingPathComponent:@".lrps2" isDirectory:YES]; }

- (NSURL *)workingCard { return [self.workingDirectory URLByAppendingPathComponent:@"Homebrew Test.ps2"]; }

- (NSURL *)legacyCard { return [self.saveDirectory URLByAppendingPathComponent:@"Homebrew Test.ps2"]; }

- (NSURL *)saveRAMForGameID:(NSString *)gameID {
    return [self.saveDirectory URLByAppendingPathComponent:[gameID stringByAppendingPathExtension:@"srm"]];
}

- (SELibretroHost *)hostWithSystem:(NSURL *)system error:(NSError **)error {
    return [self hostForGame:self.game gameID:@"ps2-game" system:system error:error];
}

- (SELibretroHost *)hostForGame:(NSURL *)game gameID:(NSString *)gameID system:(NSURL *)system error:(NSError **)error {
    [NSFileManager.defaultManager createDirectoryAtURL:self.saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    return [[SELibretroHost alloc] initWithCoreID:SECoreIDLRPS2 romURL:game saveRAMURL:[self saveRAMForGameID:gameID]
                                  systemDirectory:system error:error];
}

/// Fraction of pixels in the frame equal to the sprite colour (XRGB8888, any alpha).
- (double)spriteCoverage:(SELibretroHost *)host {
    NSData *frame = host.frameBufferData;
    const uint32_t *px = static_cast<const uint32_t *>(frame.bytes);
    NSUInteger n = frame.length / 4, hits = 0;
    for (NSUInteger i = 0; i < n; i++) {
        // RGBA 40 80 FF; the GS scales colour by 0x80 = 1.0, so allow a step of rounding.
        int r = (px[i] >> 16) & 0xFF, g = (px[i] >> 8) & 0xFF, b = px[i] & 0xFF;
        if (abs(r - 0x40) <= 2 && abs(g - 0x80) <= 2 && abs(b - 0xFF) <= 2) hits++;
    }
    return n ? double(hits) / double(n) : 0;
}

- (void)testCoreIsLinkedAndReportsSystemInfo {
    XCTAssertTrue([SELibretroHost.availableCoreIDs containsObject:SECoreIDLRPS2]);
    retro_system_info info = {};
    se_core_lrps2()->get_system_info(&info);
    XCTAssertEqualObjects(@(se_core_lrps2()->identifier), SECoreIDLRPS2);
    XCTAssertTrue(info.need_fullpath, @"discs are opened by path");
    NSArray *extensions = [@(info.valid_extensions) componentsSeparatedByString:@"|"];
    for (NSString *ext in @[@"iso", @"chd", @"cso", @"cue", @"elf", @"gz", @"m3u"]) {
        XCTAssertTrue([extensions containsObject:ext], @"%@ missing from %@", ext, extensions);
    }
    XCTAssertFalse([extensions containsObject:@"zip"], @"block_extract core: zip is not loadable");
}

- (void)testMissingBIOSFailsWithErrorAndCoreStaysUsable {
    NSError *error = nil;
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:NO] error:&error];
    XCTAssertNil(host);
    XCTAssertTrue([error.localizedDescription containsString:@"pcsx2/bios"], @"%@", error);
    BOOL logged = NO;
    @synchronized (_log) {
        for (NSString *line in _log) logged |= [line containsString:@"BIOS image"];
    }
    XCTAssertTrue(logged, @"core should log the missing BIOS; log: %@", _log);
    XCTAssertNil(SELibretroHost.activeHost);

    host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
}

- (void)testSyntheticBIOSRendersSoftwareFramesAndPicksBIOSOption {
    NSError *error = nil;
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@ log: %@", error, _log);
    if (!host) return;
    XCTAssertEqualObjects(host.coreID, SECoreIDLRPS2);
    XCTAssertTrue([host.coreVersion containsString:@"3053b13"], @"%@", host.coreVersion);
    XCTAssertEqualObjects(host.coreOptions[@"pcsx2_renderer"], @"Software (SW)");
    XCTAssertEqualObjects(host.coreOptions[@"pcsx2_bios"], @"se_synthetic.bin");
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [host runFrames:300];
    double seconds = CFAbsoluteTimeGetCurrent() - start;
    NSLog(@"LRPS2 synthetic BIOS: 300 frames in %.2f s (%.0f fps)", seconds, 300 / seconds);
    XCTAssertEqualObjects(host.renderPath, @"software");
    XCTAssertGreaterThanOrEqual(host.frameWidth, 320);
    XCTAssertGreaterThanOrEqual(host.frameHeight, 224);
    double coverage = [self spriteCoverage:host];
    XCTAssertGreaterThan(coverage, 0.2, @"sprite should fill a large part of the %ldx%ld frame",
                         (long)host.frameWidth, (long)host.frameHeight);
}

- (void)testStateRoundTripReplaysFrames {
    NSError *error = nil;
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:120];
    NSData *state = [host serializeState];
    XCTAssertGreaterThan(state.length, 1024u * 1024u);
    [host runFrames:10];
    NSData *frame = host.frameBufferData;
    XCTAssertTrue([host unserializeState:state]);
    [host runFrames:10];
    XCTAssertEqualObjects(host.frameBufferData, frame, @"frames after a restore should match");
    XCTAssertGreaterThan([self spriteCoverage:host], 0.2);

    NSURL *stateURL = [_tempDirectory URLByAppendingPathComponent:@"ps2.state"];
    XCTAssertTrue([host saveStateToURL:stateURL error:&error], @"%@", error);
    [host shutdown];
    host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    XCTAssertTrue([host loadStateFromURL:stateURL error:&error], @"%@", error);
    [host runFrames:10];
    XCTAssertGreaterThan([self spriteCoverage:host], 0.2);
}

- (void)testMemoryCardIsPerGameInSaveDirectory {
    NSError *error = nil;
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    [host runFrames:30];
    [host shutdown];
    NSURL *card = self.workingCard;
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:card.path],
                  @"slot 1 card is named after the content; saves: %@",
                  [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.workingDirectory.path error:nil]);
}

// An 8 MB PS2 card with ECC: 16384 pages of 528 bytes.
static const NSUInteger kCardSize = 16384 * 528;
static const unsigned kSavePage = 100 * 528;

static NSData *CardBytes(NSData *card) {
    return card.length >= kSavePage + 512 ? [card subdataWithRange:NSMakeRange(kSavePage, 512)] : nil;
}

static NSData *SaveBytes(uint8_t seed) {
    uint8_t bytes[512];
    uint32_t x = seed * 2654435761u + 1;
    for (int i = 0; i < 512; i++) { x = x * 1103515245u + 12345u; bytes[i] = uint8_t(x >> 16); }
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSData *BlankBytes() {
    std::vector<uint8_t> blank(512, 0xFF);
    return [NSData dataWithBytes:blank.data() length:blank.size()];
}

- (NSData *)writeLegacyCardWithSave:(NSData *)save {
    NSError *error = nil;
    std::vector<uint8_t> card(kCardSize, 0xFF);
    memcpy(&card[kSavePage], save.bytes, save.length);
    NSData *legacyCard = [NSData dataWithBytes:card.data() length:card.size()];
    [NSFileManager.defaultManager createDirectoryAtURL:self.saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertTrue([legacyCard writeToURL:self.legacyCard options:NSDataWritingAtomic error:&error], @"%@", error);
    return legacyCard;
}

- (void)testLegacyMemoryCardMigratesBeforeTheFirstFrame {
    NSError *error = nil;
    NSData *save = SaveBytes(0x31);
    NSData *legacyCard = [self writeLegacyCardWithSave:save];
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    NSURL *saveRAM = [self saveRAMForGameID:@"ps2-game"];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:saveRAM], legacyCard);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.legacyCard.path]);
    [host runFrames:30];
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:self.workingCard]), save);
    [host shutdown];
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:saveRAM]), save);
}

- (void)testUnreadableLegacyMemoryCardPreventsLaunch {
    if (geteuid() == 0) return;
    NSError *error = nil;
    NSData *legacyCard = [self writeLegacyCardWithSave:SaveBytes(0x31)];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *legacy = self.legacyCard;
    XCTAssertTrue([fm setAttributes:@{NSFilePosixPermissions: @0} ofItemAtPath:legacy.path error:&error], @"%@", error);

    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNil(host);
    XCTAssertNotNil(error);
    XCTAssertFalse([fm fileExistsAtPath:[self saveRAMForGameID:@"ps2-game"].path]);
    XCTAssertTrue([fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:legacy.path error:&error], @"%@", error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:legacy], legacyCard);
}

- (void)testMemoryCardRoundTripsThroughSaveRAMAcrossRestarts {
    NSError *error = nil;
    NSURL *system = [self systemDirectoryWithBIOS:YES];
    SELibretroHost *host = [self hostWithSystem:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    NSData *save = SaveBytes(0x21);
    XCTAssertTrue(se_core_lrps2_write_card(kSavePage, save.bytes, int(save.length)));
    [host shutdown];

    NSURL *saveRAM = [self saveRAMForGameID:@"ps2-game"];
    NSData *stored = [NSData dataWithContentsOfURL:saveRAM];
    XCTAssertEqual(stored.length, kCardSize, @"card 1 is the game's save RAM");
    XCTAssertEqualObjects(CardBytes(stored), save, @"the game's save reaches the save RAM file");

    // A fresh device: only the synced save RAM exists, and a stale working card is in the way.
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.workingCard error:&error], @"%@", error);
    std::vector<uint8_t> stale(kCardSize, 0x00);
    [[NSData dataWithBytes:stale.data() length:stale.size()] writeToURL:self.workingCard atomically:YES];

    host = [self hostWithSystem:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    [host runFrames:30];
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:self.workingCard]), save,
                          @"the core's card is loaded from save RAM");
    NSData *more = SaveBytes(0x05);
    std::vector<uint8_t> merged(512);
    for (int i = 0; i < 512; i++) merged[i] = ((const uint8_t *)save.bytes)[i] & ((const uint8_t *)more.bytes)[i];
    XCTAssertTrue(se_core_lrps2_write_card(kSavePage, more.bytes, int(more.length)));
    [host shutdown];
    stored = [NSData dataWithContentsOfURL:saveRAM];
    XCTAssertEqual(stored.length, kCardSize);
    XCTAssertEqualObjects(CardBytes(stored), [NSData dataWithBytes:merged.data() length:merged.size()],
                          @"writes after a restart build on the restored card");
}

/// Writes a save RAM file holding a card with `save` at the test page.
- (NSData *)storeCardWithSave:(NSData *)save gameID:(NSString *)gameID {
    std::vector<uint8_t> card(kCardSize, 0xFF);
    memcpy(&card[kSavePage], save.bytes, save.length);
    NSData *data = [NSData dataWithBytes:card.data() length:card.size()];
    [NSFileManager.defaultManager createDirectoryAtURL:self.saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToURL:[self saveRAMForGameID:gameID] atomically:YES];
    return data;
}

- (void)testSaveRAMMatchesTheClosedCardFile {
    NSError *error = nil;
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    NSData *save = SaveBytes(0x63);
    XCTAssertTrue(se_core_lrps2_write_card(kSavePage, save.bytes, int(save.length)));
    [host shutdown];
    // The core keeps the card's checksum word apart while it runs; save RAM must carry the
    // updated one, or a state saved before a restart sees a changed card and ejects it.
    NSData *stored = [NSData dataWithContentsOfURL:[self saveRAMForGameID:@"ps2-game"]];
    XCTAssertTrue([stored isEqualToData:[NSData dataWithContentsOfURL:self.workingCard]],
                  @"save RAM is the card as its file holds it");
}

- (void)testShortWorkingCardDoesNotShrinkSaveRAM {
    NSError *error = nil;
    NSData *save = SaveBytes(0x11);
    NSData *stored = [self storeCardWithSave:save gameID:@"ps2-game"];
    [NSFileManager.defaultManager createDirectoryAtURL:self.workingDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData dataWithBytes:stored.bytes length:kCardSize / 2] writeToURL:self.workingCard atomically:YES];

    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    [host shutdown];
    NSData *after = [NSData dataWithContentsOfURL:[self saveRAMForGameID:@"ps2-game"]];
    XCTAssertEqual(after.length, kCardSize, @"a damaged working card is replaced, not adopted");
    XCTAssertEqualObjects(CardBytes(after), save);
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:self.workingCard]), save);
}

- (void)testFailedRestoreLeavesSaveRAMAlone {
    NSError *error = nil;
    NSData *stored = [self storeCardWithSave:SaveBytes(0x29) gameID:@"ps2-game"];
    std::vector<uint8_t> other(kCardSize, 0x00);
    [NSFileManager.defaultManager createDirectoryAtURL:self.workingDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData dataWithBytes:other.data() length:other.size()] writeToURL:self.workingCard atomically:YES];
    // The card is staged next to the working copy; a directory in the way makes that fail.
    NSURL *staged = [self.workingDirectory URLByAppendingPathComponent:@"Homebrew Test.ps2.tmp" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:staged withIntermediateDirectories:YES attributes:nil error:nil];

    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    XCTAssertTrue([host flushSaveRAMWithError:&error], @"%@", error);
    [host shutdown];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self saveRAMForGameID:@"ps2-game"]], stored,
                          @"the game's save is not overwritten with a card that is not its own");
}

- (void)testClosedCardIsNotFlushedOverSaveRAM {
    NSError *error = nil;
    NSData *stored = [self storeCardWithSave:SaveBytes(0x5a) gameID:@"ps2-game"];
    SELibretroHost *host = [self hostWithSystem:[self systemDirectoryWithBIOS:YES] error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    // What a reopen that failed after the restore leaves behind: slot 1 closed, reads as zeros.
    se_core_lrps2_set_cards_open(false);
    XCTAssertTrue([host flushSaveRAMWithError:&error], @"%@", error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self saveRAMForGameID:@"ps2-game"]], stored,
                          @"a closed card is not flushed as zeros over the game's save");
    se_core_lrps2_set_cards_open(true);
    [host shutdown];
}

- (void)testSameFileNameInDifferentFoldersGetsSeparateCards {
    NSError *error = nil;
    NSURL *system = [self systemDirectoryWithBIOS:YES];
    NSURL *first = [self gameInFolder:@"USA"], *second = [self gameInFolder:@"Europe"];
    NSData *firstSave = SaveBytes(0x31), *secondSave = SaveBytes(0x47);

    SELibretroHost *host = [self hostForGame:first gameID:@"game-usa" system:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    if (!host) return;
    [host runFrames:30];
    XCTAssertTrue(se_core_lrps2_write_card(kSavePage, firstSave.bytes, int(firstSave.length)));
    [host shutdown];

    host = [self hostForGame:second gameID:@"game-eu" system:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    [host runFrames:30];
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:self.workingCard]), BlankBytes(),
                          @"the second game starts on a blank card, not the first game's");
    XCTAssertTrue(se_core_lrps2_write_card(kSavePage, secondSave.bytes, int(secondSave.length)));
    [host shutdown];

    host = [self hostForGame:first gameID:@"game-usa" system:system error:&error];
    XCTAssertNotNil(host, @"%@", error);
    [host runFrames:30];
    [host shutdown];

    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:[self saveRAMForGameID:@"game-usa"]]), firstSave);
    XCTAssertEqualObjects(CardBytes([NSData dataWithContentsOfURL:[self saveRAMForGameID:@"game-eu"]]), secondSave);
}

@end
#endif
