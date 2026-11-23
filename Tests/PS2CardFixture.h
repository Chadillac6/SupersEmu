#include <stdint.h>
#include <string.h>

static void ps2CardFixtureWord(uint8_t *dest, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) dest[i] = (uint8_t)(value >> (8 * i));
}

static void ps2CardFixtureDirectory(uint8_t *entry, const char *name) {
    memset(entry, 0, 512);
    entry[0] = 0x27;
    entry[1] = 0x84;
    memcpy(entry + 0x40, name, strlen(name) + 1);
}

static void ps2CardFixtureFormat(uint8_t *image, const char *saveFolder) {
    const unsigned cluster = 2 * 528;
    memcpy(image, "Sony PS2 Memory Card Format 1.2.0.0", 35);
    ps2CardFixtureWord(image + 0x28, 512 | (2u << 16));
    ps2CardFixtureWord(image + 0x30, 8192);
    ps2CardFixtureWord(image + 0x34, 41);
    ps2CardFixtureWord(image + 0x38, 8135);
    ps2CardFixtureWord(image + 0x3C, 0);
    ps2CardFixtureWord(image + 0x50, 8);
    image[0x150] = 2;
    ps2CardFixtureWord(image + 8 * cluster, 9);
    ps2CardFixtureWord(image + 9 * cluster, 0x80000003u);
    ps2CardFixtureDirectory(image + 41 * cluster, ".");
    ps2CardFixtureWord(image + 41 * cluster + 4, 3);
    ps2CardFixtureDirectory(image + 41 * cluster + 528, "..");
    ps2CardFixtureDirectory(image + 44 * cluster, saveFolder);
}
