//
//  EBCoreGlue.h
//  EarthboundWrapper
//
//  The only bridge between Swift and the libretro core.
//
//  `libretro.h` is included strictly from EBCoreGlue.c. Nothing in this header
//  exposes a libretro type: the API is plain C scalars, `void *`, and small
//  structs of C scalars. That keeps Swift's Clang importer away from libretro's
//  variadic log callback, enums with INT_MAX sentinels, and nested structs, and
//  it means the Swift side can be reviewed without knowing the core's ABI.
//
//  The env-command and joypad constants that Swift needs are mirrored in
//  Swift/Core/LibretroConstants.swift; EBCoreGlue.c static-asserts every one of
//  them against the real header, so drift is a compile error, not a bug.
//

#ifndef EB_CORE_GLUE_H
#define EB_CORE_GLUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Core lifecycle
//
// Thin pass-throughs over the libretro entry points, declared by hand so the
// bridging header never needs libretro.h. EBCoreGlue.c static-asserts that each
// signature still matches the core's declaration.

void eb_retro_init(void);
void eb_retro_deinit(void);
unsigned eb_retro_api_version(void);

void eb_retro_set_environment(bool (*callback)(unsigned command, void *data));
void eb_retro_set_video_refresh(void (*callback)(const void *data, unsigned width,
                                                 unsigned height, size_t pitch));
void eb_retro_set_audio_sample_batch(size_t (*callback)(const int16_t *data, size_t frames));
void eb_retro_set_input_poll(void (*callback)(void));
void eb_retro_set_input_state(int16_t (*callback)(unsigned port, unsigned device,
                                                  unsigned index, unsigned id));

/// `gameInfo` points at a `struct retro_game_info` filled by
/// `eb_build_game_info`. Returns false if the core refused the content.
bool eb_retro_load_game(void *gameInfo);
void eb_retro_unload_game(void);
void eb_retro_run(void);
void eb_retro_reset(void);
void eb_retro_set_controller_port_device(unsigned port, unsigned device);

/// Save states. The size is queried fresh each time rather than cached, because
/// a core is free to report a different size once content is loaded.
/// `serialize` writes the core's state into a caller-owned buffer; `unserialize`
/// reads it back. Both return false if the core refuses the state.
size_t eb_retro_serialize_size(void);
bool eb_retro_serialize(void *data, size_t size);
bool eb_retro_unserialize(const void *data, size_t size);

/// The `RETRO_MEMORY_*` id is passed straight through.
void *eb_retro_get_memory_data(unsigned id);
size_t eb_retro_get_memory_size(unsigned id);

// MARK: - Core-visible descriptors (flattened)

/// Flattened `struct retro_system_info`.
typedef struct {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
} eb_system_info_t;

void eb_get_system_info(eb_system_info_t *out);

/// Flattened `struct retro_system_av_info`.
typedef struct {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
    double fps;
    double sample_rate;
} eb_av_info_t;

void eb_get_system_av_info(eb_av_info_t *out);

/// Writes a `struct retro_game_info` into `gameInfo`, which must be at least
/// `eb_game_info_size()` bytes. Lives here so Swift can describe content
/// without importing the struct.
size_t eb_game_info_size(void);
void eb_build_game_info(void *gameInfo, const char *path, const void *data,
                        size_t size, const char *meta);

// MARK: - Core options

/// Key of the option inside a `struct retro_variable` handed to
/// RETRO_ENVIRONMENT_GET_VARIABLE.
const char *eb_variable_key(const void *variable);

/// Writes a value into a `struct retro_variable`.
/// The caller keeps `value` alive; the core only reads it during the call.
void eb_variable_set_value(void *variable, const char *value);

/// Copies up to `capacity` bytes of an unsized `const void *` payload.
uint32_t eb_read_u32(const void *pointer);

// MARK: - Logging

/// Receives log lines the core emits through `retro_log_printf_t`.
/// `level` matches `enum retro_log_level` (0 = debug … 3 = error).
typedef void (*eb_log_sink_t)(int level, const char *message);

/// Sets the destination for core log lines. Pass NULL to drop them.
void eb_set_log_sink(eb_log_sink_t sink);

/// Fills a `struct retro_log_callback` (inaccessible from Swift because of its
/// variadic function pointer member) with a C-implemented logger.
/// `callbackPointer` must point at a valid `struct retro_log_callback`.
void eb_install_log_callback(void *callbackPointer);

// MARK: - Input

/// Ports we track. The SNES has two; we only ever feed port 0.
#define EB_MAX_PORTS 4

/// Lock-free input snapshot. The UI thread stores a joypad bitmask, the
/// emulation thread loads it inside `retro_run()`. Each bit is independent and
/// a one-frame delay is harmless, so relaxed ordering is sufficient and the
/// audio thread is never blocked by a lock.
typedef struct eb_input eb_input_t;

eb_input_t *eb_input_create(void);
void eb_input_destroy(eb_input_t *input);
void eb_input_set_mask(eb_input_t *input, unsigned port, uint32_t mask);
uint32_t eb_input_mask(eb_input_t *input, unsigned port);

// MARK: - Lock-free audio ring (single producer, single consumer)

/// Byte-oriented SPSC ring. The emulation thread is the only writer, the
/// CoreAudio render thread the only reader. Neither ever blocks the other, and
/// an over- or under-run degrades into dropped or silent samples rather than a
/// glitch in the game loop.
typedef struct eb_ring eb_ring_t;

eb_ring_t *eb_ring_create(size_t capacityBytes);
void eb_ring_destroy(eb_ring_t *ring);

/// Returns the bytes actually written (fewer than `count` when full).
size_t eb_ring_write(eb_ring_t *ring, const void *src, size_t count);

/// Returns the bytes actually read.
size_t eb_ring_read(eb_ring_t *ring, void *dst, size_t count);

size_t eb_ring_available(const eb_ring_t *ring);
size_t eb_ring_capacity(const eb_ring_t *ring);
void eb_ring_clear(eb_ring_t *ring);

// MARK: - Time

/// Monotonic nanoseconds on the same clock as Swift's `DispatchTime`.
uint64_t eb_monotonic_nanos(void);

/// Sleeps for `nanos`, abandoning the wait early (returning true) if `flag`
/// becomes non-zero. Used to make the emulation thread's frame pacing
/// interruptible without polling.
bool eb_sleep_until(uint64_t deadlineNanos, const volatile int *flag);

#ifdef __cplusplus
}
#endif

#endif /* EB_CORE_GLUE_H */
