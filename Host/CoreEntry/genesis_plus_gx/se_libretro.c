// Includes the vendor frontend so the host can report acceptance without patching the submodule.
#include "../../../Vendor/cores/genesis_plus_gx/libretro/libretro.c"

static unsigned accepted;

void se_gpgx_cheat_reset(void) {
    retro_cheat_reset();
    accepted = 0;
}

void se_gpgx_cheat_set(unsigned index, bool enabled, const char *code) {
    if (!code || strlen(code) > 240 || strchr(code, '+')) return;
    char text[256];
    strcpy(text, code);
    // The vendor decoder writes into a cheat slot. Preserve the last entry when full.
    const int scratch = maxcheats < MAX_CHEATS ? maxcheats : MAX_CHEATS - 1;
    const CHEATENTRY saved = cheatlist[scratch];
    const bool valid = decode_cheat(text, scratch) != 0;
    const CHEATENTRY patch = cheatlist[scratch];
    cheatlist[scratch] = saved;
    if (!valid) return;

    int i;
    for (i = 0; i < maxcheats; ++i)
        if (cheatlist[i].address == patch.address && cheatlist[i].data == patch.data) break;
    if (i == MAX_CHEATS) return;

    clear_cheats();
    if (i == maxcheats) {
        cheatlist[maxcheats++] = patch;
    }
    cheatlist[i].enable = enabled;
    apply_cheats();
    ++accepted;
}

unsigned se_gpgx_cheat_count(void) {
    return accepted;
}
