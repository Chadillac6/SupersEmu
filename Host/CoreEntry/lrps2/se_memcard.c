/* PS2 saves live on memory card 1, which LRPS2 keeps as "<content name>.ps2" in its save directory.
 * Exposing that card as save RAM lets the host keep and sync it per game ID, like other cores'
 * .srm files. The file in the core's save directory is a working copy: every load replaces it with
 * the game's own card (or a blank one), so games that share a file name never share saves. */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "libretro.h"
#include "MemoryCardFile.h"
#include "CDVD/IsoFS/iso9660.h"

const char *host_content_name(void);

/* The size the core gives a card it creates (8 MB with ECC). Fixed, so a damaged working copy
 * cannot shrink the game's save. */
#define CARD_PAGE_SIZE 528
#define CARD_CLUSTER_SIZE (2 * CARD_PAGE_SIZE)
#define CARD_CLUSTERS 8192
#define CARD_SIZE (CARD_CLUSTERS * CARD_CLUSTER_SIZE)
#define CARD_CHECKSUM_AT 0x210
#define MAX_SYSTEM_CNF_SIZE (1024 * 1024)

static u8 *cardBuffer;
static size_t cardSize;
/* The game's card could not be put in place: nothing is flushed, so its save RAM stays as it was. */
static bool cardUnavailable;
/* The first save RAM request after a load is the host's load; it is copied to the card before
 * the EE first runs (it stays parked from retro_load_game until the first retro_run). */
static bool awaitingHostLoad;
static bool pendingHostLoad;
static char cardPath[PCSX2_PATH_MAX];

/* Slot 1's card, when it is this content's own card (per-game cards are on). */
static bool isContentCard(void) {
    const char *content = host_content_name();
    const char *name;
    char expected[PCSX2_PATH_MAX];
    if (!content[0] || !FileMcd_IsPresent(0, 0) || FileMcd_IsPSX(0, 0)) return false;
    if (!emu_config_mcd(0, cardPath, sizeof(cardPath)) || !cardPath[0]) return false;
    name = strrchr(cardPath, '/');
    name = name ? name + 1 : cardPath;
    snprintf(expected, sizeof(expected), "%s.ps2", content);
    return strcmp(name, expected) == 0;
}

/* The card as its file holds it once closed: the core keeps the checksum word apart from the
 * card's bytes while it runs and writes it back on close. */
static bool readCard(u8 *dest, size_t offset, size_t length) {
    u64 checksum;
    size_t from, to;
    /* A closed card reads as zeros, which must never be flushed over the game's save. */
    if (!FileMcd_IsPresent(0, 0) || !FileMcd_Read(0, 0, dest, (u32)offset, (int)length)) return false;
    checksum = FileMcd_GetCRC(0, 0);
    from = offset > CARD_CHECKSUM_AT ? offset : CARD_CHECKSUM_AT;
    to = offset + length < CARD_CHECKSUM_AT + sizeof(checksum) ? offset + length : CARD_CHECKSUM_AT + sizeof(checksum);
    if (from < to) memcpy(dest + (from - offset), (const u8 *)&checksum + (from - CARD_CHECKSUM_AT), to - from);
    return true;
}

static bool allBytes(const u8 *data, size_t size, u8 value) {
    size_t i;
    for (i = 0; i < size; i++)
        if (data[i] != value) return false;
    return true;
}

/* Compared a chunk at a time, so nothing is allocated once the game is running. */
static bool cardMatches(const u8 *expected, u8 fill) {
    u8 chunk[528 * 4];
    size_t offset, length, i;
    for (offset = 0; offset < cardSize; offset += length) {
        length = cardSize - offset < sizeof(chunk) ? cardSize - offset : sizeof(chunk);
        if (!readCard(chunk, offset, length)) return false;
        if (expected) {
            if (memcmp(chunk, expected + offset, length) != 0) return false;
        } else {
            for (i = 0; i < length; i++)
                if (chunk[i] != fill) return false;
        }
    }
    return true;
}

static void applyHostLoad(void) {
    bool hostHasCard, same, replaced = false;
    if (!pendingHostLoad) return;
    pendingHostLoad = false;
    hostHasCard = !allBytes(cardBuffer, cardSize, 0);
    same = cardMatches(hostHasCard ? cardBuffer : NULL, 0xff);
    if (same) return;
    /* Closed first: closing writes the old card's checksum word back into its file. */
    FileMcd_EmuClose();
    if (hostHasCard) {
        char staged[PCSX2_PATH_MAX + 4];
        FILE *file;
        snprintf(staged, sizeof(staged), "%s.tmp", cardPath);
        file = fopen(staged, "wb");
        if (file) {
            bool written = fwrite(cardBuffer, 1, cardSize, file) == cardSize;
            written = fclose(file) == 0 && written;
            replaced = written && rename(staged, cardPath) == 0;
            if (!replaced) remove(staged);
        }
    } else {
        /* No card for this game yet: the core makes a blank one when it opens a missing file. */
        replaced = remove(cardPath) == 0 || errno == ENOENT;
    }
    FileMcd_EmuOpen();
    cardUnavailable = !replaced || !FileMcd_IsPresent(0, 0);
}

bool se_lrps2_load_game(const struct retro_game_info *game) {
    awaitingHostLoad = pendingHostLoad = cardUnavailable = false;
    cardSize = 0;
    if (!retro_load_game(game)) return false;
    if (!isContentCard()) return true;
    if (!cardBuffer && !(cardBuffer = (u8 *)malloc(CARD_SIZE))) return true;
    cardSize = CARD_SIZE;
    awaitingHostLoad = true;
    return true;
}

static bool sameFile(const struct stat *first, const struct stat *second) {
    return first->st_dev == second->st_dev && first->st_ino == second->st_ino;
}

static bool readLegacyCard(const char *path, const struct stat *legacy) {
    struct stat opened;
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    bool verified = fstat(fileno(file), &opened) == 0 && sameFile(&opened, legacy)
        && fread(cardBuffer, 1, cardSize, file) == cardSize && fgetc(file) == EOF && !ferror(file);
    return fclose(file) == 0 && verified;
}

static bool isSerial(const u8 *text) {
    unsigned i;
    for (i = 0; i < 4; i++)
        if (text[i] < 'A' || text[i] > 'Z') return false;
    if (text[4] != '-') return false;
    for (i = 5; i < 10; i++)
        if (text[i] < '0' || text[i] > '9') return false;
    return true;
}

static bool bootPathSerial(char *bootPath, u8 serial[10]) {
    const char *exe;
    char *end;
    size_t length, i;
    end = bootPath + strlen(bootPath);
    while (end > bootPath && isspace((unsigned char)end[-1])) *--end = '\0';
    exe = end;
    while (exe > bootPath && exe[-1] != '\\' && exe[-1] != '/' && exe[-1] != ':') exe--;
    length = strcspn(exe, ";");
    if (length != 11 || (exe[4] != '_' && exe[4] != '-') || exe[8] != '.') return false;
    for (i = 0; i < 4; i++) serial[i] = (u8)toupper((unsigned char)exe[i]);
    serial[4] = '-';
    memcpy(serial + 5, exe + 5, 3);
    memcpy(serial + 8, exe + 9, 2);
    return isSerial(serial);
}

static bool readDiscSerial(u8 serial[10]) {
    isofs_file_t *file = (isofs_file_t *)malloc(sizeof(*file));
    char line[512];
    bool found = false;
    if (!file) return false;
    /* The EE is still parked. Use the mounted disc, with the same size cap as disc detection. */
    if (isofs_file_open(file, NULL, "SYSTEM.CNF;1") && file->length <= MAX_SYSTEM_CNF_SIZE) {
        while (!isofs_file_eof(file)) {
            u32 start = file->offset;
            size_t length = isofs_file_read_line(file, line, sizeof(line));
            size_t keyLength;
            bool complete = file->offset - start <= length + 1;
            char *key, *value, *equals = strchr(line, '=');
            if (!equals) continue;
            value = equals + 1;
            while (isspace((unsigned char)*value)) value++;
            if (!*value && complete && !isofs_file_eof(file)) continue;
            key = line;
            while (isspace((unsigned char)*key)) key++;
            keyLength = (size_t)(equals - key);
            while (keyLength && isspace((unsigned char)key[keyLength - 1])) keyLength--;
            if (keyLength == 5 && memcmp(key, "BOOT2", 5) == 0)
                found = complete && bootPathSerial(value, serial);
            else if (keyLength == 4 && memcmp(key, "BOOT", 4) == 0)
                found = false;
        }
    }
    free(file);
    return found;
}

static u32 cardWord(const u8 *field) {
    return (u32)field[0] | (u32)field[1] << 8 | (u32)field[2] << 16 | (u32)field[3] << 24;
}

static u32 clusterWord(u32 cluster, u32 word) {
    return cardWord(cardBuffer + cluster * CARD_CLUSTER_SIZE + word / 128 * CARD_PAGE_SIZE + word % 128 * 4);
}

static bool isLiveDirectory(const u8 *entry) {
    return (entry[0] & 0x30) == 0x20 && (entry[1] & 0x80);
}

static bool cardMatchesDiscSerial(const u8 serial[10]) {
    u32 alloc, allocatable, cluster = 0, indirect, left;
    bool found = false;
    const u8 *entry;

    if (memcmp(cardBuffer, "Sony PS2 Memory Card Format ", 28) != 0 ||
        cardWord(cardBuffer + 0x28) != (512 | 2u << 16) ||
        cardWord(cardBuffer + 0x30) != CARD_CLUSTERS || cardWord(cardBuffer + 0x3C) != 0 ||
        cardBuffer[0x150] != 2) return false;
    alloc = cardWord(cardBuffer + 0x34);
    allocatable = cardWord(cardBuffer + 0x38);
    indirect = cardWord(cardBuffer + 0x50);
    /* Version 1.1 may store the second backup block's absolute start in alloc_end. */
    if (memcmp(cardBuffer + 0x1C, "1.1.", 4) == 0) {
        u32 clustersPerBlock = (cardWord(cardBuffer + 0x2C) & 0xFFFFu) / 2;
        u32 backupBlock = cardWord(cardBuffer + 0x44);
        if (clustersPerBlock && clustersPerBlock <= 8 && backupBlock < CARD_CLUSTERS / clustersPerBlock &&
            allocatable == backupBlock * clustersPerBlock && allocatable > alloc) allocatable -= alloc;
    }
    if (alloc >= CARD_CLUSTERS || allocatable == 0 || allocatable > CARD_CLUSTERS - alloc ||
        indirect == 0 || indirect >= alloc) return false;
    entry = cardBuffer + alloc * CARD_CLUSTER_SIZE;
    left = cardWord(entry + 4);
    if (left < 2 || left > 2 * allocatable || !isLiveDirectory(entry) ||
        memcmp(entry + 0x40, ".", 2) != 0 || memcmp(entry + CARD_PAGE_SIZE + 0x40, "..", 3) != 0) return false;

    /* Each root-directory cluster holds two entries; FAT indexes are allocation-relative. */
    while (left) {
        u32 i, fat, next;
        for (i = 0; i < 2 && left; i++, left--) {
            const u8 *name;
            entry = cardBuffer + (alloc + cluster) * CARD_CLUSTER_SIZE + i * CARD_PAGE_SIZE;
            name = entry + 0x40;
            if (!isLiveDirectory(entry) || name[0] != 'B' || name[1] < 'A' || name[1] > 'Z' ||
                !isSerial(name + 2)) continue;
            if (!memchr(name, '\0', 32) || memcmp(name + 2, serial, 10) != 0) return false;
            found = true;
        }
        fat = clusterWord(indirect, cluster / 256);
        if (fat == 0 || fat >= alloc || fat == indirect) return false;
        next = clusterWord(fat, cluster % 256);
        if (!left) return found && next == 0xFFFFFFFFu;
        if (!(next & 0x80000000u)) return false;
        cluster = next & 0x7FFFFFFFu;
        if (cluster >= allocatable) return false;
    }
    return false;
}

bool se_core_lrps2_migrate_legacy_card(const char *legacyDirectory, const char *saveRAMPath, bool *migrated) {
    struct stat legacy, stored;
    char legacyPath[PCSX2_PATH_MAX];
    const char *name;
    int length;
    u8 serial[10];
    bool alreadyLinked = false;
    *migrated = false;
    if (!awaitingHostLoad) return true;
    name = strrchr(cardPath, '/');
    length = snprintf(legacyPath, sizeof(legacyPath), "%s/%s", legacyDirectory, name ? name + 1 : cardPath);
    if (length < 0 || (size_t)length >= sizeof(legacyPath)) return false;
    if (lstat(legacyPath, &legacy) != 0) return errno == ENOENT;
    if (lstat(saveRAMPath, &stored) == 0) {
        if (!S_ISREG(stored.st_mode) || stored.st_size != CARD_SIZE) return false;
        /* Resume if interrupted between linking and removing the old name. */
        if (!sameFile(&stored, &legacy)) return true;
        alreadyLinked = true;
    } else {
        if (errno != ENOENT || !S_ISREG(legacy.st_mode) || legacy.st_size != CARD_SIZE) return false;
    }
    if (!readLegacyCard(legacyPath, &legacy)) return false;
    /* Do not fall through to loadSaveRAM if an interrupted migration published an unverified card. */
    if (!readDiscSerial(serial) || !cardMatchesDiscSerial(serial)) return !alreadyLinked;
    if (!alreadyLinked) {
        /* Both paths are in Saves, so publishing the same inode does not overwrite save RAM. */
        if (link(legacyPath, saveRAMPath) != 0) return false;
        if (lstat(saveRAMPath, &stored) != 0 || !sameFile(&stored, &legacy)) return false;
    }
    if (unlink(legacyPath) != 0 && errno != ENOENT) return false;
    /* Use the verified snapshot instead of asking the host to read the file again. */
    pendingHostLoad = true;
    awaitingHostLoad = false;
    *migrated = true;
    return true;
}

void se_lrps2_run(void) {
    applyHostLoad();
    retro_run();
}

void se_lrps2_deinit(void) {
    retro_deinit();
    free(cardBuffer);
    cardBuffer = NULL;
    cardSize = 0;
    awaitingHostLoad = pendingHostLoad = cardUnavailable = false;
}

void *se_lrps2_get_memory_data(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_data(type);
    if (!cardSize) return NULL;
    if (awaitingHostLoad) {
        awaitingHostLoad = false;
        pendingHostLoad = true;
        memset(cardBuffer, 0, cardSize);
        return cardBuffer;
    }
    applyHostLoad();
    if (cardUnavailable) return NULL;
    /* A snapshot: the card itself is only written through FileMcd. Taken while the EE may be
     * running, it holds what the core's own write-through file holds at that moment. */
    if (!readCard(cardBuffer, 0, cardSize)) return NULL;
    return cardBuffer;
}

size_t se_lrps2_get_memory_size(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_size(type);
    return cardSize;
}

/* Test hook: a game's write to card 1 (what the SIO does when a game saves). */
bool se_core_lrps2_write_card(unsigned address, const void *data, int size) {
    return FileMcd_Save(0, 0, (const u8 *)data, address, size) == 1;
}

void se_core_lrps2_set_cards_open(bool open) {
    if (open) FileMcd_EmuOpen();
    else FileMcd_EmuClose();
}
