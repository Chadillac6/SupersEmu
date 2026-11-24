// Compiles the vendored Genesis Plus GX libretro frontend in this translation unit so SupersEmu can
// read its file-static cheat count without patching the submodule. Bad codes are skipped silently
// by retro_cheat_set, so the host compares this count before and after each call.
#include "../../../Vendor/cores/genesis_plus_gx/libretro/libretro.c"

unsigned se_gpgx_cheat_count(void) {
    return (unsigned)maxcheats;
}
