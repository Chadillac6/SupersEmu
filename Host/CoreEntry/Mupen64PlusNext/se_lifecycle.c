#include "libretro.h"

extern int g_EmulatorRunning;
void hleRomClosed(void);
static bool loaded;

// The core is statically linked, so its globals outlive a session. The HLE RSP's microcode
// cache is only reset by hleRomClosed, which the core never calls; reset it per game.
bool se_mupen64plus_next_load_game(const struct retro_game_info *game) {
    hleRomClosed();
    loaded = retro_load_game(game);
    return loaded;
}

// retro_deinit stops the emulator by resuming its coroutine once. If no frame has run yet,
// that resume starts emulation instead of stopping it, and the ROM stays open for the next
// session. Start it first so the stop takes.
void se_mupen64plus_next_deinit(void) {
    if (loaded && !g_EmulatorRunning) retro_run();
    loaded = false;
    retro_deinit();
}

// The core refuses a state until its first frame has initialised the emulator, so a state
// loaded straight after the game (resume) runs that frame first.
bool se_mupen64plus_next_unserialize(const void *data, size_t size) {
    if (retro_unserialize(data, size)) return true;
    if (!loaded || g_EmulatorRunning) return false;
    retro_run();
    return retro_unserialize(data, size);
}
