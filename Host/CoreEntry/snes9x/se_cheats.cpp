// Lets SELibretroHost tell whether retro_cheat_set accepted a code (Snes9x only printf()s rejections).
#include "snes9x.h"
#include "cheats.h"

extern "C" unsigned se_snes9x_cheat_count(void) {
    return static_cast<unsigned>(Cheat.group.size());
}
