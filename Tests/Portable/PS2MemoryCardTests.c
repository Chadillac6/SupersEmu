#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "libretro.h"
#include "MemoryCardFile.h"
#include "../PS2CardFixture.h"

bool se_lrps2_load_game(const struct retro_game_info *game);
bool se_core_lrps2_migrate_legacy_card(const char *legacyDirectory, const char *saveRAMPath, bool *migrated);
void se_lrps2_run(void);
void se_lrps2_deinit(void);
void *se_lrps2_get_memory_data(unsigned type);
size_t se_lrps2_get_memory_size(unsigned type);

#define CARD_SIZE (16384 * 528)
#define SAVE_OFFSET (100 * 528)

static char cardPath[4096];
static FILE *card;
static u8 image[CARD_SIZE];
static const char *bootELF = "cdrom0:\\SLUS_203.12;1";

static void check(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

const char *host_content_name(void) { return "Test"; }

int GetPS2ElfName(char *name, size_t size) {
    snprintf(name, size, "%s", bootELF ? bootELF : "");
    return bootELF ? 2 : 0;
}

bool emu_config_mcd(uint slot, char *path, size_t size) {
    return slot == 0 && snprintf(path, size, "%s", cardPath) < (int)size;
}

void FileMcd_EmuOpen(void) {
    card = fopen(cardPath, "r+b");
    if (card) return;
    card = fopen(cardPath, "w+b");
    check(card != NULL, "create blank card");
    u8 blank[528];
    memset(blank, 0xff, sizeof(blank));
    for (size_t i = 0; i < CARD_SIZE / sizeof(blank); i++)
        check(fwrite(blank, 1, sizeof(blank), card) == sizeof(blank), "write blank card");
}

void FileMcd_EmuClose(void) { if (card) fclose(card); card = NULL; }
s32 FileMcd_IsPresent(uint port, uint slot) { return port == 0 && slot == 0 && card != NULL; }
bool FileMcd_IsPSX(uint port, uint slot) { (void)port; (void)slot; return false; }

s32 FileMcd_Read(uint port, uint slot, u8 *data, u32 addr, int size) {
    return FileMcd_IsPresent(port, slot) && fseek(card, addr, SEEK_SET) == 0
        && fread(data, 1, size, card) == (size_t)size;
}

s32 FileMcd_Save(uint port, uint slot, const u8 *data, u32 addr, int size) {
    return FileMcd_IsPresent(port, slot) && fseek(card, addr, SEEK_SET) == 0
        && fwrite(data, 1, size, card) == (size_t)size;
}

u64 FileMcd_GetCRC(uint port, uint slot) {
    u64 result;
    check(FileMcd_Read(port, slot, (u8 *)&result, 0x210, sizeof(result)), "read checksum");
    return result;
}

bool retro_load_game(const struct retro_game_info *game) { (void)game; FileMcd_EmuOpen(); return true; }
void retro_run(void) {}
void retro_deinit(void) { FileMcd_EmuClose(); }
void *retro_get_memory_data(unsigned type) { (void)type; return NULL; }
size_t retro_get_memory_size(unsigned type) { (void)type; return 0; }

static void writeImage(const char *path) {
    FILE *file = fopen(path, "wb");
    check(file != NULL, "open card fixture");
    check(fwrite(image, 1, sizeof(image), file) == sizeof(image), "write card fixture");
    check(fclose(file) == 0, "close card fixture");
}

static void writeCard(const char *path, u8 progress) {
    memset(image, 0xff, sizeof(image));
    ps2CardFixtureFormat(image, "BASLUS-20312SAVE");
    image[SAVE_OFFSET] = progress;
    writeImage(path);
}

static void loadSaveRAM(const char *path) {
    void *buffer = se_lrps2_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = se_lrps2_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    check(buffer != NULL && size == CARD_SIZE, "get host load buffer");
    FILE *file = fopen(path, "rb");
    if (file) {
        check(fread(buffer, 1, size, file) == size, "read exact-size save RAM");
        fclose(file);
    }
}

static void checkProgress(u8 expected, const char *message) {
    u8 progress;
    check(FileMcd_Read(0, 0, &progress, SAVE_OFFSET, 1) && progress == expected, message);
}

int main(int argc, char **argv) {
    check(argc == 2, "test requires a save directory");
    char legacy[4096], working[4096], saveRAM[4096], secondSaveRAM[4096];
    snprintf(legacy, sizeof(legacy), "%s/Test.ps2", argv[1]);
    snprintf(working, sizeof(working), "%s/.lrps2", argv[1]);
    snprintf(cardPath, sizeof(cardPath), "%s/.lrps2/Test.ps2", argv[1]);
    snprintf(saveRAM, sizeof(saveRAM), "%s/game.srm", argv[1]);
    snprintf(secondSaveRAM, sizeof(secondSaveRAM), "%s/other-game.srm", argv[1]);
    check(mkdir(working, 0700) == 0, "create dedicated working directory");
    writeCard(legacy, 0x31);

    bool migrated;
    bootELF = "cdrom0:\\SLUS_203.13;1";
    check(se_lrps2_load_game(NULL), "load a different serial with the same basename");
    check(se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated,
          "different disc serial must not migrate a same-basename PS2 card");
    check(access(legacy, F_OK) == 0 && access(secondSaveRAM, F_OK) != 0, "keep the legacy card unclaimed");
    loadSaveRAM(secondSaveRAM);
    se_lrps2_run();
    checkProgress(0xff, "mismatched legacy progress does not reach the running game");
    se_lrps2_deinit();
    puts("PASS: a different disc serial cannot claim the legacy card");

    check(link(legacy, secondSaveRAM) == 0, "stage an interrupted migration");
    check(se_lrps2_load_game(NULL), "load a different serial after interrupted migration");
    check(!se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated,
          "do not load an unverified card from an interrupted migration");
    check(access(legacy, F_OK) == 0, "interrupted migration still preserves the original card");
    se_lrps2_deinit();
    check(unlink(secondSaveRAM) == 0, "remove the staged destination");
    puts("PASS: an interrupted migration cannot bypass serial validation");

    bootELF = NULL;
    check(se_lrps2_load_game(NULL), "load a game without a disc serial");
    check(se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated,
          "no disc serial must skip migration");
    check(access(legacy, F_OK) == 0 && access(secondSaveRAM, F_OK) != 0, "keep the legacy card without a serial");
    se_lrps2_deinit();
    puts("PASS: a missing disc serial leaves the legacy card untouched");

    bootELF = "cdrom0:\\SLUS_203.12;1";
    ps2CardFixtureWord(image + 41 * 2 * 528 + 4, 4);
    ps2CardFixtureDirectory(image + 89 * 528, "BESLES-20312SAVE");
    writeImage(legacy);
    check(se_lrps2_load_game(NULL), "load game with a mixed-serial card");
    check(se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated,
          "a matching folder does not make a different game's progress safe to migrate");
    check(access(legacy, F_OK) == 0 && access(secondSaveRAM, F_OK) != 0, "keep mixed-serial legacy card");
    se_lrps2_deinit();
    puts("PASS: a card with another game's directory is not migrated");

    writeCard(legacy, 0x31);
    image[88 * 528 + 1] &= 0x7F;
    memcpy(image + SAVE_OFFSET + 0x40, "BASLUS-20312SAVE", 17);
    writeImage(legacy);
    check(se_lrps2_load_game(NULL), "load game with matching bytes outside live root entries");
    check(se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated,
          "deleted folders and save data are not live directory entries");
    check(access(legacy, F_OK) == 0 && access(secondSaveRAM, F_OK) != 0, "keep legacy card without live match");
    se_lrps2_deinit();
    puts("PASS: deleted entries and matching data bytes do not authorize migration");

    writeCard(legacy, 0x31);
    check(se_lrps2_load_game(NULL), "load game on upgrade");
    check(se_core_lrps2_migrate_legacy_card(argv[1], saveRAM, &migrated) && migrated, "migrate legacy card");
    se_lrps2_run();
    checkProgress(0x31, "first frame replaced the legacy Test.ps2 progress with a blank card");
    const void *saved = se_lrps2_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    check(saved != NULL && memcmp(saved, image, sizeof(image)) == 0, "legacy card reaches save RAM byte for byte");
    se_lrps2_deinit();
    check(access(legacy, F_OK) != 0 && access(saveRAM, F_OK) == 0, "legacy card is claimed once");
    puts("PASS: legacy PS2 progress survives the first frame and reaches save RAM");

    check(se_lrps2_load_game(NULL), "load second game with a matching filename");
    check(se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated) && !migrated, "skip already migrated card");
    loadSaveRAM(secondSaveRAM);
    se_lrps2_run();
    checkProgress(0xff, "a second game starts blank, not with the first game's card");
    se_lrps2_deinit();
    puts("PASS: another game with the same filename starts with a blank card");

    writeCard(legacy, 0x92);
    check(se_lrps2_load_game(NULL), "reload game with existing save RAM");
    check(se_core_lrps2_migrate_legacy_card(argv[1], saveRAM, &migrated) && !migrated, "keep existing save RAM");
    loadSaveRAM(saveRAM);
    se_lrps2_run();
    checkProgress(0x31, "existing save RAM wins over the legacy card");
    se_lrps2_deinit();
    puts("PASS: existing per-game save RAM takes precedence");

    check(mkdir(secondSaveRAM, 0700) == 0, "block the migration destination");
    check(se_lrps2_load_game(NULL), "load game with blocked migration destination");
    check(!se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated), "report failed migration");
    se_lrps2_deinit();
    FILE *source = fopen(legacy, "rb");
    check(source && fread(image, 1, sizeof(image), source) == sizeof(image) && image[SAVE_OFFSET] == 0x92,
          "failed migration preserves the legacy image");
    fclose(source);
    puts("PASS: a blocked destination leaves the legacy card untouched");

    check(rmdir(secondSaveRAM) == 0, "unblock the migration destination");
    if (geteuid() != 0) {
        check(chmod(legacy, 0) == 0, "make the legacy card unreadable");
        check(se_lrps2_load_game(NULL), "open working card with an unreadable legacy card");
        check(!se_core_lrps2_migrate_legacy_card(argv[1], secondSaveRAM, &migrated), "reject an unreadable legacy card");
        se_lrps2_deinit();
        check(chmod(legacy, 0600) == 0, "legacy card remains at its original path");
        check(access(secondSaveRAM, F_OK) != 0, "failed verification does not leave a save RAM file");
        source = fopen(legacy, "rb");
        check(source && fread(image, 1, sizeof(image), source) == sizeof(image) && image[SAVE_OFFSET] == 0x92,
              "unreadable legacy progress is preserved");
        fclose(source);
        puts("PASS: unreadable legacy progress is preserved and migration fails");
    } else {
        puts("SKIP: unreadable legacy card test requires an unprivileged user");
    }
    return 0;
}
