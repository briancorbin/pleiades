// The desk-bench wire protocol: the CAN frame layout Electra-on-a-wire
// transmits and Merope decodes. Signal ids reuse the OBD-II PID codes
// (0x0C = rpm, 0x0D = speed, …) so the whole stack — C ring, event files,
// Swift UI — speaks one signal vocabulary.
//
// This is NOT the real Forester's layout; the real decode table arrives with
// car recon (opendbc-derived). Same decoder shape, different table.
#ifndef MEROPE_FRAMES_H
#define MEROPE_FRAMES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "merope_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MRP_ID_TELEM_A 0x510  // rpm, speed, coolant, throttle, load
#define MRP_ID_TELEM_B 0x511  // voltage, intake temp, fuel, manifold
#define MRP_ID_STATUS 0x520   // MIL + stored-code count

typedef struct {
    uint16_t id;
    uint8_t len;
    uint8_t data[8];
} mrp_can_frame_t;

// Encoders — the fake car's side.
mrp_can_frame_t mrp_frame_telem_a(float rpm, float speed_kmh, float coolant_c,
                                  float throttle_pct, float load_pct);
mrp_can_frame_t mrp_frame_telem_b(float voltage, float intake_c, float fuel_pct,
                                  float map_kpa);
mrp_can_frame_t mrp_frame_status(bool mil_on, uint8_t dtc_count);

// Decoder — Merope's side. Emits (now_ms, pid-signal, value) samples ready
// for mrp_ring_push. Returns the number written; 0 for unknown/status frames.
size_t mrp_frame_decode(const mrp_can_frame_t *frame, uint32_t now_ms,
                        mrp_sample_t *out, size_t out_max);

// True when the frame is MRP_ID_STATUS; fills the watcher's inputs.
bool mrp_frame_status_decode(const mrp_can_frame_t *frame, bool *mil_on,
                             uint8_t *dtc_count);

#ifdef __cplusplus
}
#endif

#endif  // MEROPE_FRAMES_H
