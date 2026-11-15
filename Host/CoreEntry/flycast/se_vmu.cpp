// Dreamcast saves live on the VMU in controller A's first slot. Exposing its flash as save RAM lets
// the host persist and sync it per game like other cores' .srm files.
#include "types.h"
#include "hw/maple/maple_if.h"
#include "oslib/oslib.h"
#include "libretro.h"
#include <cstdio>
#include <cstring>

extern "C" bool retro_load_game(const struct retro_game_info *game);
extern "C" void retro_run(void);
extern "C" void *retro_get_memory_data(unsigned type);
extern "C" size_t retro_get_memory_size(unsigned type);

static constexpr size_t kVMUSize = 128 * 1024;
// Flycast (re)creates the VMUs during its first frames, after the host has loaded save RAM, so the
// host's load goes into this buffer and is copied to the card (and its file) once a frame has run.
static u8 *pendingVMU;
static bool awaitingHostLoad;

static maple_device *vmuA1() {
    const auto &device = MapleDevices[0][0];
    return device && device->get_device_type() == MDT_SegaVMU ? device.get() : nullptr;
}

static void applyPendingVMU(maple_device *vmu) {
    u8 *pending = pendingVMU;
    pendingVMU = nullptr;
    bool written = false;
    for (size_t i = 0; i < kVMUSize && !written; i++) written = pending[i] != 0;
    size_t size = 0;
    u8 *flash = static_cast<u8 *>(const_cast<void *>(vmu->getData(size)));
    if (written && flash && size == kVMUSize) {
        memcpy(flash, pending, kVMUSize);
        // Keep Flycast's own card file in step, since it only rewrites the blocks a game changes.
        if (FILE *file = fopen(hostfs::getVmuPath("A1", true).c_str(), "wb")) {
            fwrite(flash, kVMUSize, 1, file);
            fclose(file);
        }
    }
    delete[] pending;
}

extern "C" bool se_flycast_load_game(const struct retro_game_info *game) {
    delete[] pendingVMU;
    pendingVMU = nullptr;
    awaitingHostLoad = false;
    if (!retro_load_game(game)) return false;
    awaitingHostLoad = true;
    // Flycast only sets up expansion slots (VMUs) once every port has a device.
    for (unsigned port = 0; port < 4; port++) retro_set_controller_port_device(port, RETRO_DEVICE_JOYPAD);
    return true;
}

extern "C" void se_flycast_run(void) {
    retro_run();
    if (pendingVMU)
        if (maple_device *vmu = vmuA1()) applyPendingVMU(vmu);
}

extern "C" void *se_flycast_get_memory_data(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_data(type);
    if (awaitingHostLoad) {
        awaitingHostLoad = false;
        pendingVMU = new u8[kVMUSize]();
    }
    if (pendingVMU) return pendingVMU;
    maple_device *vmu = vmuA1();
    size_t size;
    return vmu ? const_cast<void *>(vmu->getData(size)) : nullptr;
}

extern "C" size_t se_flycast_get_memory_size(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_size(type);
    return pendingVMU || awaitingHostLoad || vmuA1() ? kVMUSize : 0;
}
