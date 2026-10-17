// Compiled into each core library with SE_CORE_ID (e.g. gambatte) and SE_CORE_REVISION
// (pinned upstream commit) defined by project.yml.
#include "libretro.h"
#include "SECoreAPI.h"

#define SE_STR_(x) #x
#define SE_STR(x) SE_STR_(x)
#define SE_ENTRY_(id) se_core_##id
#define SE_ENTRY(id) SE_ENTRY_(id)

// A core can wrap retro_load_game (e.g. to reject content it silently mis-loads).
#ifdef SE_CORE_LOAD_GAME
bool SE_CORE_LOAD_GAME(const struct retro_game_info *game);
#else
#define SE_CORE_LOAD_GAME retro_load_game
#endif

#ifdef SE_CORE_DEINIT
void SE_CORE_DEINIT(void);
#else
#define SE_CORE_DEINIT retro_deinit
#endif

#ifdef SE_CORE_UNSERIALIZE
bool SE_CORE_UNSERIALIZE(const void *data, size_t size);
#else
#define SE_CORE_UNSERIALIZE retro_unserialize
#endif

// Cores with cheat support may expose a count; cores without one report Unverified.
#if defined(SE_CORE_CHEAT_COUNT) || defined(SE_CORE_CHEATS)
#ifdef SE_CORE_CHEAT_RESET
void SE_CORE_CHEAT_RESET(void);
#define SE_CHEAT_RESET SE_CORE_CHEAT_RESET
#else
#define SE_CHEAT_RESET retro_cheat_reset
#endif
#ifdef SE_CORE_CHEAT_SET
void SE_CORE_CHEAT_SET(unsigned, bool, const char *);
#define SE_CHEAT_SET SE_CORE_CHEAT_SET
#else
#define SE_CHEAT_SET retro_cheat_set
#endif
#else
#define SE_CHEAT_RESET NULL
#define SE_CHEAT_SET NULL
#endif

#ifdef SE_CORE_CHEAT_COUNT
unsigned SE_CORE_CHEAT_COUNT(void);
#else
#define SE_CORE_CHEAT_COUNT NULL
#endif

const SECoreAPI *SE_ENTRY(SE_CORE_ID)(void) {
    static const SECoreAPI api = {
        SE_STR(SE_CORE_ID), SE_STR(SE_CORE_REVISION),
        retro_set_environment, retro_set_video_refresh, retro_set_audio_sample,
        retro_set_audio_sample_batch, retro_set_input_poll, retro_set_input_state,
        retro_init, SE_CORE_DEINIT, retro_get_system_info, retro_get_system_av_info,
        retro_set_controller_port_device, retro_run, retro_reset, retro_serialize_size, retro_serialize,
        SE_CORE_UNSERIALIZE, SE_CORE_LOAD_GAME, retro_unload_game, retro_get_memory_data,
        retro_get_memory_size, SE_CHEAT_RESET, SE_CHEAT_SET, SE_CORE_CHEAT_COUNT,
    };
    return &api;
}
