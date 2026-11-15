/* PS2 saves live on memory card 1, which LRPS2 keeps as "<content name>.ps2" in the save directory.
 * Exposing that card as save RAM lets the host keep and sync it per game ID, like other cores'
 * .srm files. The file in the save directory becomes a working copy: every load replaces it with
 * the game's own card (or a blank one), so games that share a file name never share saves. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "libretro.h"
#include "MemoryCardFile.h"

const char *host_content_name(void);

static u8 *cardBuffer;
static size_t cardSize;
/* The first save RAM request after a load is the host's load; it is copied to the card before
 * the EE first runs (it stays parked from retro_load_game until the first retro_run). */
static bool awaitingHostLoad;
static bool pendingHostLoad;
static char cardPath[PCSX2_PATH_MAX];

/* Slot 1's card, when it is this content's own card (per-game cards are on). */
static size_t contentCardSize(void) {
    const char *content = host_content_name();
    const char *name;
    struct stat info;
    char expected[PCSX2_PATH_MAX];
    if (!content[0] || !FileMcd_IsPresent(0, 0) || FileMcd_IsPSX(0, 0)) return 0;
    if (!emu_config_mcd(0, cardPath, sizeof(cardPath)) || !cardPath[0]) return 0;
    name = strrchr(cardPath, '/');
    name = name ? name + 1 : cardPath;
    snprintf(expected, sizeof(expected), "%s.ps2", content);
    if (strcmp(name, expected) != 0) return 0;
    if (stat(cardPath, &info) != 0 || info.st_size <= 0) return 0;
    return (size_t)info.st_size;
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
        if (!FileMcd_Read(0, 0, chunk, (u32)offset, (int)length)) return false;
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
    bool hostHasCard, same;
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
            if (!written || rename(staged, cardPath) != 0) remove(staged);
        }
    } else {
        /* No card for this game yet: the core makes a blank one when it opens a missing file. */
        remove(cardPath);
    }
    FileMcd_EmuOpen();
}

bool se_lrps2_load_game(const struct retro_game_info *game) {
    size_t size;
    awaitingHostLoad = pendingHostLoad = false;
    cardSize = 0;
    if (!retro_load_game(game)) return false;
    size = contentCardSize();
    if (size && size != cardSize) {
        u8 *buffer = (u8 *)realloc(cardBuffer, size);
        if (!buffer) return true;
        cardBuffer = buffer;
    }
    cardSize = size;
    awaitingHostLoad = size > 0;
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
    awaitingHostLoad = pendingHostLoad = false;
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
    /* A snapshot: the card itself is only written through FileMcd. Taken while the EE may be
     * running, it holds what the core's own write-through file holds at that moment. */
    if (!FileMcd_Read(0, 0, cardBuffer, 0, (int)cardSize)) return NULL;
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
