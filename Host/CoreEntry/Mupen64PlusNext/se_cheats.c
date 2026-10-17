#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "main/main.h"
#include "main/cheat.h"
#include "main/list.h"
#include "m64p_types.h"

void se_mupen64plus_next_cheat_set(unsigned index, bool enabled, const char *code) {
    uint32_t parts[128];
    m64p_cheat_code codes[64];
    size_t part_count = 0;
    const char *cursor = code;
    char name[32];

    if (!code) return;
    while (*cursor) {
        char token[9];
        size_t length = 0;
        unsigned long value;

        while (isspace((unsigned char)*cursor)) cursor++;
        if (!*cursor) break;
        if (part_count == sizeof(parts) / sizeof(parts[0])) return;
        while (*cursor && !isspace((unsigned char)*cursor)) {
            if (!isxdigit((unsigned char)*cursor) || length == sizeof(token) - 1) return;
            token[length++] = *cursor++;
        }
        if (!length) return;
        token[length] = '\0';
        errno = 0;
        value = strtoul(token, NULL, 16);
        if (errno || value > UINT32_MAX) return;
        parts[part_count++] = (uint32_t)value;
    }

    size_t code_count = part_count / 2;
    if (!code_count) return;
    for (size_t i = 0; i < code_count; i++) {
        codes[i].address = parts[i * 2];
        codes[i].value = (int)parts[i * 2 + 1];
    }
    snprintf(name, sizeof(name), "cheat_%u", index);
    cheat_add_new(&g_cheat_ctx, name, codes, (int)code_count);
    cheat_set_enabled(&g_cheat_ctx, name, enabled);
}

unsigned se_mupen64plus_next_cheat_count(void) {
    unsigned count = 0;
    struct list_head *node;
    for (node = g_cheat_ctx.active_cheats.next; node != &g_cheat_ctx.active_cheats; node = node->next) {
        count++;
    }
    return count;
}
