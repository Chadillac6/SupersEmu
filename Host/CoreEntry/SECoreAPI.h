// Function table for one statically linked libretro core.
// Every libretro core defines the same retro_* symbols, so each core library is prelinked
// into a single object that exports only its se_core_<id>() entry point (see core.exports).
// Include the core's own libretro.h before this header.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SECoreAPI {
    const char *identifier;
    const char *revision;
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*run)(void);
    void (*reset)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *, size_t);
    bool (*unserialize)(const void *, size_t);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
    /// NULL for cores without cheat support in SupersEmu.
    void (*cheat_reset)(void);
    void (*cheat_set)(unsigned, bool, const char *);
    /// Codes the core currently holds, so the host can tell an accepted code from a rejected one.
    unsigned (*cheat_count)(void);
} SECoreAPI;

const SECoreAPI *se_core_snes9x(void);
const SECoreAPI *se_core_gambatte(void);
const SECoreAPI *se_core_mgba(void);
const SECoreAPI *se_core_genesis_plus_gx(void);
const SECoreAPI *se_core_beetle_psx(void);
const SECoreAPI *se_core_picodrive(void);
const SECoreAPI *se_core_mupen64plus_next(void);

#ifdef __cplusplus
}
#endif
