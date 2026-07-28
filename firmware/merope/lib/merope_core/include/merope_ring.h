// Rolling telemetry ring buffer. Plain C, no allocation, no platform calls —
// the same code runs in PSRAM on the ESP32 and in a test harness on the Mac.
#ifndef MEROPE_RING_H
#define MEROPE_RING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One decoded signal update. 12 bytes; at a few hundred updates/sec the
// 8 MB PSRAM part holds well over an hour.
typedef struct {
    uint32_t ms;      // milliseconds since boot
    uint16_t signal;  // signal id (from the DBC-derived table)
    float value;
} mrp_sample_t;

typedef struct {
    mrp_sample_t *buf;  // caller-owned storage
    size_t capacity;
    size_t head;   // next write slot
    size_t count;  // valid samples (<= capacity)
} mrp_ring_t;

void mrp_ring_init(mrp_ring_t *r, mrp_sample_t *storage, size_t capacity);

// Append one sample, overwriting the oldest when full.
void mrp_ring_push(mrp_ring_t *r, mrp_sample_t sample);

size_t mrp_ring_count(const mrp_ring_t *r);

// Copy every sample with ms >= since_ms into out (oldest first), up to
// out_max. Returns the number copied.
size_t mrp_ring_window(const mrp_ring_t *r, uint32_t since_ms,
                       mrp_sample_t *out, size_t out_max);

#ifdef __cplusplus
}
#endif

#endif  // MEROPE_RING_H
