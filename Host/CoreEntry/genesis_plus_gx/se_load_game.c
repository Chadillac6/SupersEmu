// retro_load_game wrapper for Genesis Plus GX (SE_CORE_LOAD_GAME, see SECoreEntry.c).
#include <string.h>
#include <strings.h>
#include "shared.h"

static int is_disc_path(const char *path) {
    const char *dot = path ? strrchr(path, '.') : NULL;
    return dot && (!strcasecmp(dot, ".cue") || !strcasecmp(dot, ".chd") ||
                   !strcasecmp(dot, ".iso") || !strcasecmp(dot, ".m3u"));
}

bool se_gpgx_load_game(const struct retro_game_info *game) {
    // The core is linked statically, so its "BIOS already loaded" flags outlive retro_deinit;
    // clear them so every load re-reads (and requires) bios_CD_*.bin from the system directory.
    system_bios = 0;
    if (!retro_load_game(game)) return false;
    // A disc image whose tracks can't be read falls back to loading the file as a cartridge.
    if (is_disc_path(game ? game->path : NULL) && system_hw != SYSTEM_MCD) {
        retro_unload_game();
        return false;
    }
    return true;
}
