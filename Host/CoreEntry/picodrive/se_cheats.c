#include "pico/patch.h"

unsigned se_picodrive_cheat_count(void) {
    return (unsigned)PicoPatchCount;
}
