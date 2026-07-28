// Fault-event serialization: the byte format Merope writes to flash and
// Alcyone downloads over BLE. Versioned, little-endian, no padding games —
// the same encoder/decoder runs on the ESP32 and in host tests (and the
// Swift importer implements the mirror of this layout).
//
// Layout v1:
//   "MRPE"            4  magic
//   version           1  (currently 1)
//   trigger_ms        4  u32le, ms-since-boot of the fault edge
//   mil_on            1  0/1
//   dtc_count         1
//   sample_count      2  u16le
//   samples           sample_count × (ms u32le, signal u16le, value f32le)
#ifndef MEROPE_EVENT_H
#define MEROPE_EVENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "merope_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MRP_EVENT_VERSION 1
#define MRP_EVENT_HEADER_SIZE 13
#define MRP_EVENT_SAMPLE_SIZE 10

typedef struct {
    uint32_t trigger_ms;
    bool mil_on;
    uint8_t dtc_count;
    uint16_t sample_count;
    const mrp_sample_t *samples;  // borrowed, not owned
} mrp_event_t;

size_t mrp_event_encoded_size(uint16_t sample_count);

// Returns bytes written, or 0 if out_max is too small.
size_t mrp_event_encode(const mrp_event_t *event, uint8_t *out, size_t out_max);

// Decodes into *event, writing samples into samples_out (event->samples
// points there). Returns false on bad magic/version/truncation or when
// samples_max is too small.
bool mrp_event_decode(const uint8_t *buf, size_t len, mrp_event_t *event,
                      mrp_sample_t *samples_out, uint16_t samples_max);

#ifdef __cplusplus
}
#endif

#endif  // MEROPE_EVENT_H
