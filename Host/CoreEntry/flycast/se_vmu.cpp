// Dreamcast saves live on the VMU in controller A's first slot. Exposing its flash as save RAM lets
// the host persist and sync it per game like other cores' .srm files.
#include "types.h"
#include "hw/maple/maple_if.h"
#include "libretro.h"

extern "C" void *retro_get_memory_data(unsigned type);
extern "C" size_t retro_get_memory_size(unsigned type);

static const void *vmuA1(size_t &size) {
    size = 0;
    const auto &device = MapleDevices[0][0];
    if (!device || device->get_device_type() != MDT_SegaVMU) return nullptr;
    return device->getData(size);
}

extern "C" void *se_flycast_get_memory_data(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_data(type);
    size_t size;
    return const_cast<void *>(vmuA1(size));
}

extern "C" size_t se_flycast_get_memory_size(unsigned type) {
    if (type != RETRO_MEMORY_SAVE_RAM) return retro_get_memory_size(type);
    size_t size;
    return vmuA1(size) ? size : 0;
}
