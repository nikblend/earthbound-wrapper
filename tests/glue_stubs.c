/*
 * Stub libretro entry points, so EBCoreGlue.c links in a test binary.
 *
 * The glue re-exports the core's entry points, so linking it requires *something*
 * to define them. Nothing here emulates anything; the point is to give the ring
 * buffer and the input word a real linker and a real process to run in.
 *
 * Including libretro.h rather than hand-declaring these is deliberate: it means a
 * signature that no longer matches the pinned core is a compile error here too,
 * which makes this file a second, independent check on the same thing
 * EBCoreGlue.c's `EB_CHECK_SIGNATURE` block asserts.
 */

#include <libretro.h>
#include <string.h>
#include <time.h>

static struct retro_system_info g_system_info;
static struct retro_system_av_info g_av_info;
static unsigned char g_save_ram[8192];

void retro_init(void) {}
void retro_deinit(void) {}
unsigned retro_api_version(void) { return RETRO_API_VERSION; }

void retro_set_environment(retro_environment_t cb) { (void)cb; }
void retro_set_video_refresh(retro_video_refresh_t cb) { (void)cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { (void)cb; }
void retro_set_input_poll(retro_input_poll_t cb) { (void)cb; }
void retro_set_input_state(retro_input_state_t cb) { (void)cb; }
void retro_set_controller_port_device(unsigned port, unsigned device) {
    (void)port;
    (void)device;
}

void retro_get_system_info(struct retro_system_info *info) {
    memset(&g_system_info, 0, sizeof(g_system_info));
    g_system_info.library_name = "stub";
    g_system_info.library_version = "0";
    g_system_info.valid_extensions = "sfc|smc";
    g_system_info.need_fullpath = false;
    *info = g_system_info;
}

void retro_get_system_av_info(struct retro_system_av_info *info) {
    memset(&g_av_info, 0, sizeof(g_av_info));
    g_av_info.geometry.base_width = 256;
    g_av_info.geometry.base_height = 224;
    g_av_info.geometry.max_width = 512;
    g_av_info.geometry.max_height = 478;
    g_av_info.geometry.aspect_ratio = 4.0f / 3.0f;
    g_av_info.timing.fps = 60.0988;
    g_av_info.timing.sample_rate = 32040.0;
    *info = g_av_info;
}

bool retro_load_game(const struct retro_game_info *game) {
    (void)game;
    return true;
}
void retro_unload_game(void) {}
unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
void retro_run(void) {}
void retro_reset(void) {}

size_t retro_serialize_size(void) { return 0; }
bool retro_serialize(void *data, size_t size) { (void)data; (void)size; return false; }
bool retro_unserialize(const void *data, size_t size) { (void)data; (void)size; return false; }

void *retro_get_memory_data(unsigned id) {
    return id == RETRO_MEMORY_SAVE_RAM ? g_save_ram : NULL;
}

size_t retro_get_memory_size(unsigned id) {
    return id == RETRO_MEMORY_SAVE_RAM ? sizeof(g_save_ram) : 0;
}

/* Backs the mach_absolute_time shim. */
uint64_t eb_test_monotonic_nanos(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}
