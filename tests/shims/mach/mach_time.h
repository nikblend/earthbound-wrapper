/*
 * Minimal mach_time stand-in.
 *
 * Enough for EBCoreGlue.c to compile and for the ring buffer tests to run on a
 * Linux box, where the real header does not exist. The test that needs a clock
 * (eb_sleep_until) uses a monotonic clock of its own, so this only has to answer
 * the two symbols.
 *
 * Only ever on the include path for `make test`, never for a real build.
 */

#ifndef EB_TEST_SHIM_MACH_TIME_H
#define EB_TEST_SHIM_MACH_TIME_H

#include <stdint.h>

typedef struct {
    uint32_t numer;
    uint32_t denom;
} mach_timebase_info_data_t;

static inline int mach_timebase_info(mach_timebase_info_data_t *info) {
    info->numer = 1;
    info->denom = 1;
    return 0;
}

/* A real monotonic source, so tests that measure elapsed time still work. */
uint64_t eb_test_monotonic_nanos(void);

static inline uint64_t mach_absolute_time(void) {
    return eb_test_monotonic_nanos();
}

#endif /* EB_TEST_SHIM_MACH_TIME_H */
