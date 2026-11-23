/* PS2 saves live on memory card 1, which LRPS2 keeps as "<content name>.ps2" in its save directory.
 * Exposing that card as save RAM lets the host keep and sync it per game ID, like other cores'
 * .srm files. The file in the core's save directory is a working copy: every load replaces it with
 * the game's own card (or a blank one), so games that share a file name never share saves. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "libretro.h"
#include "MemoryCardFile.h"

const char *host_content_name(void);

/* The size the core gives a card it creates (8 MB with ECC). Fixed, so a damaged working copy
 * cannot shrink the game's save. */
#define CARD_SIZE (16384 * 528)
#define CARD_CHECKSUM_AT 0x210

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

bool se_lrps2_migrate_legacy_card(const char *legacyDirectory, const char *saveRAMPath) {
    struct stat legacy, stored;
    char legacyPath[PCSX2_PATH_MAX];
    const char *name;
    int length;
    if (!awaitingHostLoad) return true;
    name = strrchr(cardPath, '/');
    length = snprintf(legacyPath, sizeof(legacyPath), "%s/%s", legacyDirectory, name ? name + 1 : cardPath);
    if (length < 0 || (size_t)length >= sizeof(legacyPath)) return false;
    if (lstat(legacyPath, &legacy) != 0) return errno == ENOENT;
    if (lstat(saveRAMPath, &stored) == 0) {
        if (!S_ISREG(stored.st_mode) || stored.st_size != CARD_SIZE) return false;
        /* Resume if interrupted between linking and removing the old name. */
        if (stored.st_dev != legacy.st_dev || stored.st_ino != legacy.st_ino) return true;
    } else {
        if (errno != ENOENT || !S_ISREG(legacy.st_mode) || legacy.st_size != CARD_SIZE) return false;
        /* Both paths are in Saves. A hard link publishes the exact bytes without overwriting
         * a save RAM file; the legacy name is only removed once that second name exists. */
        if (link(legacyPath, saveRAMPath) != 0) return false;
    }
    return unlink(legacyPath) == 0 || errno == ENOENT;
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
