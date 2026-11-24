// Lets SELibretroHost tell whether retro_cheat_set accepted a code (Snes9x only printf()s rejections).
#include "snes9x.h"
#include "cheats.h"
#include "memmap.h"

extern "C" void retro_cheat_set(unsigned index, bool enabled, const char *code);

static const uint8 *mappedByte(uint32 address) {
    const auto *base = Memory.Map[(address & 0xFFFFFF) >> MEMMAP_SHIFT];
    return reinterpret_cast<pint>(base) >= CMemory::MAP_LAST ? base + (address & 0xFFFF) : nullptr;
}

extern "C" unsigned se_snes9x_cheat_count(void) {
    return static_cast<unsigned>(Cheat.group.size());
}

extern "C" void se_snes9x_cheat_set(unsigned index, bool enabled, const char *code) {
    const auto first = Cheat.group.size();
    retro_cheat_set(index, false, code);
    if (!enabled) return;

    // The libretro frontend creates one group per code. Restore the original byte
    // before enabling a later write to that address so the two don't save each other's values.
    for (auto next = first; next < Cheat.group.size(); ++next) {
        const auto address = Cheat.group[next].cheat.front().address;
        const auto *byte = mappedByte(address);
        for (size_t prior = 0; prior < next; ++prior) {
            const auto &group = Cheat.group[prior];
            if (!group.enabled) continue;
            const auto earlier = group.cheat.front().address;
            if (earlier == address || (byte && mappedByte(earlier) == byte)) S9xDisableCheatGroup(prior);
        }
        S9xEnableCheatGroup(next);
    }
}
