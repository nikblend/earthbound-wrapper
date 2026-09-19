/*
 * Tests for the C glue.
 *
 * These run on any machine with a C compiler and no Xcode, because the pieces
 * they cover are the ones most likely to be subtly wrong and hardest to notice on
 * a phone: a lock-free ring buffer between two threads, and a single atomic word
 * shared with the UI.
 *
 * A ring buffer bug does not crash. It plays the wrong samples, or drops the ones
 * at a wrap boundary, or corrupts the ordering across a wrap — and on a device
 * that presents as "the audio crackles sometimes", which is not a debuggable
 * symptom. So the concurrency test deliberately crosses the wrap boundary many
 * times and verifies every byte's position.
 *
 *   make test
 */

#include "EBCoreGlue.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(condition, ...)                                                  \
    do {                                                                       \
        g_checks++;                                                            \
        if (!(condition)) {                                                    \
            g_failures++;                                                      \
            printf("  FAIL %s:%d: ", __FILE__, __LINE__);                      \
            printf(__VA_ARGS__);                                               \
            printf("\n");                                                      \
        }                                                                      \
    } while (0)

/* ------------------------------------------------------------------ */

static void test_ring_round_trip(void) {
    printf("ring: round trip\n");
    eb_ring_t *ring = eb_ring_create(1024);
    CHECK(ring != NULL, "allocation failed");
    CHECK(eb_ring_capacity(ring) == 1024, "capacity is not what was asked for");
    CHECK(eb_ring_available(ring) == 0, "a new ring should be empty");

    uint8_t in[256];
    uint8_t out[256];
    for (int i = 0; i < 256; i++) in[i] = (uint8_t)i;

    CHECK(eb_ring_write(ring, in, sizeof(in)) == sizeof(in), "write was truncated");
    CHECK(eb_ring_available(ring) == sizeof(in), "available does not match the write");

    memset(out, 0, sizeof(out));
    CHECK(eb_ring_read(ring, out, sizeof(out)) == sizeof(out), "read was short");
    CHECK(memcmp(in, out, sizeof(in)) == 0, "bytes did not survive the round trip");
    CHECK(eb_ring_available(ring) == 0, "ring should be empty again after a full read");

    eb_ring_destroy(ring);
}

static void test_ring_overflow_drops_the_tail(void) {
    printf("ring: overflow drops the tail, not the head\n");
    eb_ring_t *ring = eb_ring_create(64);

    uint8_t in[100];
    for (int i = 0; i < 100; i++) in[i] = (uint8_t)(0x40 + i);

    size_t written = eb_ring_write(ring, in, sizeof(in));
    CHECK(written == 64, "writing more than capacity should store exactly capacity, stored %zu",
          written);

    uint8_t out[100];
    size_t read = eb_ring_read(ring, out, sizeof(out));
    CHECK(read == 64, "read should return everything that fit, returned %zu", read);
    CHECK(memcmp(in, out, 64) == 0, "the bytes kept should be the oldest ones");

    /* The tail was dropped, not overwritten into the ring, so nothing is corrupt
     * and the buffer still works afterwards. */
    CHECK(eb_ring_write(ring, in, 32) == 32, "ring unusable after an overflow");
    CHECK(eb_ring_read(ring, out, 32) == 32, "ring unreadable after an overflow");
    eb_ring_destroy(ring);
}

static void test_ring_wraparound(void) {
    printf("ring: wraparound\n");
    eb_ring_t *ring = eb_ring_create(100);

    uint8_t out[100];
    for (int round = 0; round < 20; round++) {
        uint8_t in[60];
        for (int i = 0; i < 60; i++) in[i] = (uint8_t)(round * 60 + i);

        CHECK(eb_ring_write(ring, in, sizeof(in)) == sizeof(in),
              "round %d: write was short", round);
        /* Drain before the next write, so every write starts at a different
         * offset inside the buffer and the wrap is exercised both ways. */
        CHECK(eb_ring_read(ring, out, sizeof(out)) == sizeof(in),
              "round %d: read was short", round);
        CHECK(memcmp(in, out, sizeof(in)) == 0, "round %d: bytes corrupted across a wrap", round);
    }
    eb_ring_destroy(ring);
}

static void test_ring_clear(void) {
    printf("ring: clear\n");
    eb_ring_t *ring = eb_ring_create(128);
    uint8_t in[64] = {0};
    eb_ring_write(ring, in, sizeof(in));
    eb_ring_clear(ring);
    CHECK(eb_ring_available(ring) == 0, "clear did not empty the ring");
    /* Still usable after clearing. */
    CHECK(eb_ring_write(ring, in, sizeof(in)) == sizeof(in), "ring unusable after clear");
    eb_ring_destroy(ring);
}

/* ------------------------------------------------------------------ */

typedef struct {
    eb_ring_t *ring;
    size_t total_bytes;
    int failed;
} producer_args;

/* Writes a byte stream whose value encodes its own absolute position, so the
 * consumer can prove nothing was lost, duplicated or reordered. */
static void *producer(void *raw) {
    producer_args *args = raw;
    size_t position = 0;
    while (position < args->total_bytes) {
        uint8_t chunk[997];
        size_t want = sizeof(chunk);
        if (want > args->total_bytes - position) want = args->total_bytes - position;
        for (size_t i = 0; i < want; i++) {
            chunk[i] = (uint8_t)((position + i) * 31 + 7);
        }
        size_t offset = 0;
        while (offset < want) {
            size_t wrote = eb_ring_write(args->ring, chunk + offset, want - offset);
            if (wrote == 0) {
                /* Full. A real producer would keep the remainder and retry on its
                 * next frame, which is what this does. */
                struct timespec pause = {.tv_sec = 0, .tv_nsec = 200000};
                nanosleep(&pause, NULL);
                continue;
            }
            offset += wrote;
        }
        position += want;
    }
    return NULL;
}

static void test_ring_concurrent(void) {
    printf("ring: concurrent producer and consumer\n");

    const size_t capacity = 4096;
    const size_t total = 2 * 1024 * 1024; /* 512 wraps of the buffer */
    eb_ring_t *ring = eb_ring_create(capacity);

    producer_args args = {.ring = ring, .total_bytes = total, .failed = 0};

    pthread_t thread;
    pthread_create(&thread, NULL, producer, &args);

    size_t read_total = 0;
    size_t mismatches = 0;
    uint8_t buffer[512];
    while (read_total < total) {
        size_t got = eb_ring_read(ring, buffer, sizeof(buffer));
        if (got == 0) {
            struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000};
            nanosleep(&pause, NULL);
            continue;
        }
        for (size_t i = 0; i < got; i++) {
            uint8_t expected = (uint8_t)((read_total + i) * 31 + 7);
            if (buffer[i] != expected) mismatches++;
        }
        read_total += got;
    }

    pthread_join(thread, NULL);

    CHECK(mismatches == 0, "%zu of %zu bytes were corrupted in transit", mismatches, read_total);
    CHECK(read_total == total, "read %zu bytes, expected %zu", read_total, total);
    CHECK(eb_ring_available(ring) == 0, "ring not drained at the end");
    eb_ring_destroy(ring);
}

/* ------------------------------------------------------------------ */

typedef struct {
    eb_input_t *input;
    int failed;
} input_args;

static void *input_writer(void *raw) {
    input_args *args = raw;
    for (int i = 0; i < 1000000; i++) {
        eb_input_set_mask(args->input, 0, (uint32_t)(i & 0xFFF));
        if (eb_input_mask(args->input, 0) > 0xFFF) args->failed = 1;
    }
    return NULL;
}

static void test_input_word(void) {
    printf("input: atomic joypad word\n");

    eb_input_t *input = eb_input_create();
    CHECK(input != NULL, "allocation failed");

    eb_input_set_mask(input, 0, 0x1234);
    CHECK(eb_input_mask(input, 0) == 0x1234, "round trip failed");

    /* Boundary conditions that would be a silent buffer overrun on a device. */
    eb_input_set_mask(input, EB_MAX_PORTS - 1, 0xABCD);
    CHECK(eb_input_mask(input, EB_MAX_PORTS - 1) == 0xABCD, "last valid port failed");
    eb_input_set_mask(input, EB_MAX_PORTS, 0xFFFF); /* must be ignored, not written */
    eb_input_set_mask(input, 9999, 0xFFFF);        /* ditto */
    CHECK(eb_input_mask(input, 0) == 0x1234, "an out-of-range port wrote to port 0");
    CHECK(eb_input_mask(input, EB_MAX_PORTS) == 0, "an out-of-range port returned data");

    // Back to a value inside the range the writers use, so the reader's check is
    // about observed stores rather than about the seed above.
    eb_input_set_mask(input, 0, 0);

    input_args args = {.input = input, .failed = 0};
    pthread_t thread;
    pthread_create(&thread, NULL, input_writer, &args);
    for (int i = 0; i < 1000000; i++) {
        uint32_t value = eb_input_mask(input, 0);
        if (value > 0xFFF) args.failed = 1;
    }
    pthread_join(thread, NULL);
    CHECK(args.failed == 0, "a reader observed a value no writer ever stored");

    eb_input_destroy(input);
}

/* ------------------------------------------------------------------ */

static char g_log_message[256];
static int g_log_level = -1;

static void log_sink(int level, const char *message) {
    g_log_level = level;
    snprintf(g_log_message, sizeof(g_log_message), "%s", message);
}

/* Mirrors what the core's own logger does. `struct retro_log_callback` is not
 * visible here on purpose: the whole point of the shim is that Swift never has to
 * name it, and this test should not either. */
typedef struct {
    void (*log)(int level, const char *format, ...);
} log_callback_shape;

static void test_log_shim(void) {
    printf("log: the variadic shim formats and forwards\n");

    eb_set_log_sink(log_sink);
    g_log_level = -1;
    g_log_message[0] = '\0';

    log_callback_shape callback;
    memset(&callback, 0, sizeof(callback));
    eb_install_log_callback(&callback);

    CHECK(callback.log != NULL, "the shim installed no logger");

    if (callback.log != NULL) {
        callback.log(2, "value=%d name=%s", 42, "snes9x");
    }

    CHECK(g_log_level == 2, "level was not forwarded, got %d", g_log_level);
    CHECK(strcmp(g_log_message, "value=42 name=snes9x") == 0,
          "formatting was wrong: '%s'", g_log_message);

    /* A null sink must be tolerated: logging is optional, and a crash here would
     * be a crash during core init. */
    eb_set_log_sink(NULL);
    if (callback.log != NULL) callback.log(0, "dropped");
    CHECK(1, "unreachable");
}

static void test_descriptors(void) {
    printf("info: descriptors flatten correctly\n");

    eb_system_info_t info;
    memset(&info, 0, sizeof(info));
    eb_get_system_info(&info);
    CHECK(info.library_name && strcmp(info.library_name, "stub") == 0,
          "library_name did not flatten, got %s", info.library_name ? info.library_name : "(null)");
    CHECK(info.valid_extensions && strcmp(info.valid_extensions, "sfc|smc") == 0,
          "valid_extensions did not flatten");

    eb_av_info_t av;
    memset(&av, 0, sizeof(av));
    eb_get_system_av_info(&av);
    CHECK(av.base_width == 256 && av.base_height == 224,
          "geometry is wrong: %ux%u", av.base_width, av.base_height);
    CHECK(av.max_width == 512 && av.max_height == 478, "max geometry is wrong");
    CHECK(av.fps > 60.0 && av.fps < 60.2, "fps did not flatten: %f", av.fps);
    CHECK(av.sample_rate > 32039 && av.sample_rate < 32041,
          "sample rate did not flatten: %f", av.sample_rate);
    CHECK(av.aspect_ratio > 1.33 && av.aspect_ratio < 1.34,
          "aspect ratio did not flatten: %f", av.aspect_ratio);

    CHECK(eb_game_info_size() >= sizeof(void *) * 3,
          "the game info descriptor is suspiciously small");
    CHECK(eb_read_u32("\x78\x56\x34\x12") == 0x12345678,
          "eb_read_u32 does not read little-endian");
}

int main(void) {
    printf("eb glue tests\n\n");

    test_ring_round_trip();
    test_ring_overflow_drops_the_tail();
    test_ring_wraparound();
    test_ring_clear();
    test_ring_concurrent();
    test_input_word();
    test_log_shim();
    test_descriptors();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
