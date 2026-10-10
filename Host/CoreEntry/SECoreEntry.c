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

const SECoreAPI *SE_ENTRY(SE_CORE_ID)(void) {
    static const SECoreAPI api = {
        SE_STR(SE_CORE_ID), SE_STR(SE_CORE_REVISION),
        retro_set_environment, retro_set_video_refresh, retro_set_audio_sample,
        retro_set_audio_sample_batch, retro_set_input_poll, retro_set_input_state,
        retro_init, retro_deinit, retro_get_system_info, retro_get_system_av_info,
        retro_set_controller_port_device, retro_run, retro_serialize_size, retro_serialize,
        retro_unserialize, SE_CORE_LOAD_GAME, retro_unload_game, retro_get_memory_data,
        retro_get_memory_size,
    };
    return &api;
}
