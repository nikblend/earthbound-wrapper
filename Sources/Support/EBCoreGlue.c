//
//  EBCoreGlue.c
//  EarthboundWrapper
//
//  Everything in the app that has to know libretro's real ABI lives here.
//
//  Three jobs:
//    1. Re-export the core entry points under hand-written signatures so the
//       bridging header never has to see libretro.h.
//    2. Flatten the descriptors the frontend reads (system info, AV info, game
//       info, variables) into structs of C scalars.
//    3. Provide the real-time primitives the frontend needs: a log callback
//       (necessarily C, because the core's logger is variadic), a lock-free
//       input snapshot, and a single-producer/single-consumer audio ring.
//
//  The drift checks below turn any mismatch between our signatures, our
//  constants, and the pinned core revision into a compile error.
//

#include "EBCoreGlue.h"
#include "libretro.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <mach/mach_time.h>

// ---------------------------------------------------------------------------
// MARK: - Drift checks
//
// Every constant mirrored in LibretroConstants.swift is asserted here, and every
// re-exported entry point is assigned to a pointer of our declared type. A
// signature or value change in libretro.h breaks the build instead of becoming a
// runtime crash, so re-pinning the core revision stays a mechanical job.
// ---------------------------------------------------------------------------

// Promote a mismatched signature to a hard error. Clang needs the pragma because
// the diagnostic is a warning by default; GCC has no equivalent flag, so there the
// promotion relies on `-Werror`, which both the test build and Xcode set.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wincompatible-pointer-types"
#endif

#define EB_CHECK_SIGNATURE(returnType, function, parameters)                   \
    static returnType(*const eb_check_##function) parameters                    \
        __attribute__((unused)) = function

EB_CHECK_SIGNATURE(void, retro_set_environment, (bool (*)(unsigned, void *)));
EB_CHECK_SIGNATURE(void, retro_set_video_refresh,
                   (void (*)(const void *, unsigned, unsigned, size_t)));
EB_CHECK_SIGNATURE(void, retro_set_audio_sample_batch,
                   (size_t (*)(const int16_t *, size_t)));
EB_CHECK_SIGNATURE(void, retro_set_input_poll, (void (*)(void)));
EB_CHECK_SIGNATURE(void, retro_set_input_state,
                   (int16_t (*)(unsigned, unsigned, unsigned, unsigned)));
EB_CHECK_SIGNATURE(bool, retro_load_game, (const struct retro_game_info *));
EB_CHECK_SIGNATURE(void, retro_set_controller_port_device, (unsigned, unsigned));
EB_CHECK_SIGNATURE(void *, retro_get_memory_data, (unsigned));
EB_CHECK_SIGNATURE(size_t, retro_get_memory_size, (unsigned));

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#define EB_CHECK_CONSTANT(name, expected)                                      \
    _Static_assert((name) == (expected), #name " drifted from the pinned core")

EB_CHECK_CONSTANT(RETRO_API_VERSION, 1);

// Frontend environment commands.
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_EXPERIMENTAL, 0x10000);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_OVERSCAN, 2);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_CAN_DUPE, 3);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_MESSAGE, 6);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SHUTDOWN, 7);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL, 8);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, 9);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, 10);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS, 11);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_VARIABLE, 15);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_VARIABLES, 16);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, 17);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, 18);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, 27);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, 31);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, 32);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_GEOMETRY, 37);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_LANGUAGE, 39);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE,
                  (47 | RETRO_ENVIRONMENT_EXPERIMENTAL));
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_FASTFORWARDING,
                  (49 | RETRO_ENVIRONMENT_EXPERIMENTAL));
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE,
                  (50 | RETRO_ENVIRONMENT_EXPERIMENTAL));
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS,
                  (51 | RETRO_ENVIRONMENT_EXPERIMENTAL));
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION, 59);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, 52);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY, 30);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY, 30);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_CORE_OPTIONS, 53);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, 54);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2, 67);
EB_CHECK_CONSTANT(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, 68);

// Input, memory and pixel formats.
EB_CHECK_CONSTANT(RETRO_DEVICE_NONE, 0);
EB_CHECK_CONSTANT(RETRO_DEVICE_JOYPAD, 1);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_MASK, 256);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_B, 0);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_Y, 1);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_SELECT, 2);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_START, 3);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_UP, 4);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_DOWN, 5);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_LEFT, 6);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_RIGHT, 7);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_A, 8);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_X, 9);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_L, 10);
EB_CHECK_CONSTANT(RETRO_DEVICE_ID_JOYPAD_R, 11);

EB_CHECK_CONSTANT(RETRO_MEMORY_SAVE_RAM, 0);
EB_CHECK_CONSTANT(RETRO_MEMORY_RTC, 1);
EB_CHECK_CONSTANT(RETRO_MEMORY_SYSTEM_RAM, 2);
EB_CHECK_CONSTANT(RETRO_MEMORY_VIDEO_RAM, 3);

EB_CHECK_CONSTANT(RETRO_PIXEL_FORMAT_0RGB1555, 0);
EB_CHECK_CONSTANT(RETRO_PIXEL_FORMAT_XRGB8888, 1);
EB_CHECK_CONSTANT(RETRO_PIXEL_FORMAT_RGB565, 2);

EB_CHECK_CONSTANT(RETRO_REGION_NTSC, 0);
EB_CHECK_CONSTANT(RETRO_REGION_PAL, 1);
EB_CHECK_CONSTANT(RETRO_LANGUAGE_ENGLISH, 0);

// Layout assumptions made by the pointer-indexing tricks in Swift.
_Static_assert(sizeof(struct retro_variable) == 2 * sizeof(void *),
               "retro_variable is no longer two pointers; Swift's indexing is wrong");
_Static_assert(offsetof(struct retro_variable, value) == sizeof(void *),
               "retro_variable::value moved; Swift's indexing is wrong");

// ---------------------------------------------------------------------------
// MARK: - Lifecycle pass-throughs
// ---------------------------------------------------------------------------

void eb_retro_init(void) { retro_init(); }
void eb_retro_deinit(void) { retro_deinit(); }
unsigned eb_retro_api_version(void) { return retro_api_version(); }

void eb_retro_set_environment(bool (*callback)(unsigned, void *)) {
    retro_set_environment(callback);
}

void eb_retro_set_video_refresh(void (*callback)(const void *, unsigned, unsigned,
                                                 size_t)) {
    retro_set_video_refresh(callback);
}

void eb_retro_set_audio_sample_batch(size_t (*callback)(const int16_t *, size_t)) {
    retro_set_audio_sample_batch(callback);
}

void eb_retro_set_input_poll(void (*callback)(void)) { retro_set_input_poll(callback); }

void eb_retro_set_input_state(int16_t (*callback)(unsigned, unsigned, unsigned,
                                                  unsigned)) {
    retro_set_input_state(callback);
}

bool eb_retro_load_game(void *gameInfo) {
    return retro_load_game((const struct retro_game_info *)gameInfo);
}

void eb_retro_unload_game(void) { retro_unload_game(); }
void eb_retro_run(void) { retro_run(); }
void eb_retro_reset(void) { retro_reset(); }

void eb_retro_set_controller_port_device(unsigned port, unsigned device) {
    retro_set_controller_port_device(port, device);
}

void *eb_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t eb_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }

// ---------------------------------------------------------------------------
// MARK: - Descriptors
// ---------------------------------------------------------------------------

void eb_get_system_info(eb_system_info_t *out) {
    struct retro_system_info info;
    memset(&info, 0, sizeof(info));
    retro_get_system_info(&info);
    out->library_name = info.library_name;
    out->library_version = info.library_version;
    out->valid_extensions = info.valid_extensions;
    out->need_fullpath = info.need_fullpath;
}

void eb_get_system_av_info(eb_av_info_t *out) {
    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    out->base_width = av.geometry.base_width;
    out->base_height = av.geometry.base_height;
    out->max_width = av.geometry.max_width;
    out->max_height = av.geometry.max_height;
    out->aspect_ratio = av.geometry.aspect_ratio;
    out->fps = av.timing.fps;
    out->sample_rate = av.timing.sample_rate;
}

size_t eb_game_info_size(void) { return sizeof(struct retro_game_info); }

void eb_build_game_info(void *gameInfo, const char *path, const void *data,
                        size_t size, const char *meta) {
    struct retro_game_info *info = (struct retro_game_info *)gameInfo;
    info->path = path;
    info->data = data;
    info->size = size;
    info->meta = meta;
}

const char *eb_variable_key(const void *variable) {
    return ((const struct retro_variable *)variable)->key;
}

void eb_variable_set_value(void *variable, const char *value) {
    ((struct retro_variable *)variable)->value = value;
}

uint32_t eb_read_u32(const void *pointer) {
    uint32_t value = 0;
    memcpy(&value, pointer, sizeof(value));
    return value;
}

// ---------------------------------------------------------------------------
// MARK: - Logging
// ---------------------------------------------------------------------------

static eb_log_sink_t g_log_sink = NULL;

void eb_set_log_sink(eb_log_sink_t sink) { g_log_sink = sink; }

// Matches retro_log_printf_t exactly. C is the only option here: the core's
// logger is variadic, which Swift cannot implement or forward.
static void eb_log_printf(enum retro_log_level level, const char *fmt, ...) {
    if (g_log_sink == NULL)
        return;

    char buffer[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    g_log_sink((int)level, buffer);
}

void eb_install_log_callback(void *callbackPointer) {
    struct retro_log_callback *callback = (struct retro_log_callback *)callbackPointer;
    callback->log = eb_log_printf;
}

// ---------------------------------------------------------------------------
// MARK: - Input
// ---------------------------------------------------------------------------

struct eb_input {
    _Atomic(uint32_t) buttons[EB_MAX_PORTS];
};

eb_input_t *eb_input_create(void) { return calloc(1, sizeof(eb_input_t)); }

void eb_input_destroy(eb_input_t *input) { free(input); }

void eb_input_set_mask(eb_input_t *input, unsigned port, uint32_t mask) {
    if (input == NULL || port >= EB_MAX_PORTS)
        return;
    atomic_store_explicit(&input->buttons[port], mask, memory_order_relaxed);
}

uint32_t eb_input_mask(eb_input_t *input, unsigned port) {
    if (input == NULL || port >= EB_MAX_PORTS)
        return 0;
    return atomic_load_explicit(&input->buttons[port], memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// MARK: - SPSC audio ring
// ---------------------------------------------------------------------------

struct eb_ring {
    uint8_t *buffer;
    size_t capacity;
    // Monotonic counters rather than wrapped indices, so "full" and "empty" are
    // distinguishable without sacrificing a slot. Only the writer touches head,
    // only the reader touches tail.
    _Atomic(size_t) head;
    _Atomic(size_t) tail;
};

eb_ring_t *eb_ring_create(size_t capacityBytes) {
    eb_ring_t *ring = calloc(1, sizeof(eb_ring_t));
    if (ring == NULL)
        return NULL;

    ring->capacity = capacityBytes;
    ring->buffer = malloc(capacityBytes);
    if (ring->buffer == NULL) {
        free(ring);
        return NULL;
    }

    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    return ring;
}

void eb_ring_destroy(eb_ring_t *ring) {
    if (ring == NULL)
        return;
    free(ring->buffer);
    free(ring);
}

size_t eb_ring_capacity(const eb_ring_t *ring) { return ring ? ring->capacity : 0; }

size_t eb_ring_available(const eb_ring_t *ring) {
    if (ring == NULL)
        return 0;
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail;
}

size_t eb_ring_write(eb_ring_t *ring, const void *src, size_t count) {
    if (ring == NULL || count == 0)
        return 0;

    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);

    size_t used = head - tail;
    size_t space = ring->capacity - used;
    if (count > space)
        count = space;
    if (count == 0)
        return 0;

    size_t offset = head % ring->capacity;
    size_t first = ring->capacity - offset;
    if (first > count)
        first = count;

    memcpy(ring->buffer + offset, src, first);
    if (count > first)
        memcpy(ring->buffer, (const uint8_t *)src + first, count - first);

    atomic_store_explicit(&ring->head, head + count, memory_order_release);
    return count;
}

size_t eb_ring_read(eb_ring_t *ring, void *dst, size_t count) {
    if (ring == NULL || count == 0)
        return 0;

    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);

    size_t used = head - tail;
    if (count > used)
        count = used;
    if (count == 0)
        return 0;

    size_t offset = tail % ring->capacity;
    size_t first = ring->capacity - offset;
    if (first > count)
        first = count;

    memcpy(dst, ring->buffer + offset, first);
    if (count > first)
        memcpy((uint8_t *)dst + first, ring->buffer, count - first);

    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}

void eb_ring_clear(eb_ring_t *ring) {
    if (ring == NULL)
        return;
    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    atomic_store_explicit(&ring->tail, head, memory_order_release);
}

// ---------------------------------------------------------------------------
// MARK: - Time
// ---------------------------------------------------------------------------

uint64_t eb_monotonic_nanos(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);

    uint64_t ticks = mach_absolute_time();
    // numer/denom is 1/1 on Apple silicon and 125/3 on Intel; the 128-bit
    // intermediate keeps this exact on both.
    return (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom);
}

bool eb_sleep_until(uint64_t deadlineNanos, const volatile int *flag) {
    for (;;) {
        if (flag != NULL && *flag != 0)
            return true;

        uint64_t now = eb_monotonic_nanos();
        if (now >= deadlineNanos)
            return false;

        uint64_t remaining = deadlineNanos - now;
        // Cap each nap so a stop request is noticed promptly without polling at
        // frame rate.
        if (remaining > 2 * 1000 * 1000)
            remaining = 2 * 1000 * 1000;

        struct timespec request = {
            .tv_sec = (time_t)(remaining / 1000000000ull),
            .tv_nsec = (long)(remaining % 1000000000ull),
        };
        nanosleep(&request, NULL);
    }
}
