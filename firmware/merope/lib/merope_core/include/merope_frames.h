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
#define MRP_ID_BODY 0x530     // gate, doors, seatbelts, gear, ignition
#define MRP_ID_TPMS 0x540     // four wheel pressures

// Signal ids 0x00–0xFF are OBD PID codes (see the SIG_* table in the .c).
// Proprietary signals — the ones no dongle can ask for — live above that,
// which is the whole reason Merope exists.
#define MRP_SIG_GATE 0x100      // rear gate: 0 closed, 1 ajar/open
#define MRP_SIG_DOOR_FL 0x101
#define MRP_SIG_DOOR_FR 0x102
#define MRP_SIG_DOOR_RL 0x103
#define MRP_SIG_DOOR_RR 0x104
#define MRP_SIG_BELT_DRIVER 0x110     // 0 unbuckled, 1 buckled
#define MRP_SIG_BELT_PASSENGER 0x111
#define MRP_SIG_GEAR 0x120            // 0 P, 1 R, 2 N, 3 D
#define MRP_SIG_IGNITION 0x121        // 0 off, 1 acc, 2 run
#define MRP_SIG_TPMS_FL 0x130         // kPa
#define MRP_SIG_TPMS_FR 0x131
#define MRP_SIG_TPMS_RL 0x132
#define MRP_SIG_TPMS_RR 0x133

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

/// Body/chassis state — the proprietary frame no OBD request can retrieve.
typedef struct {
    bool gate_open;
    bool door_fl, door_fr, door_rl, door_rr;
    bool belt_driver, belt_passenger;
    uint8_t gear;      // 0 P, 1 R, 2 N, 3 D
    uint8_t ignition;  // 0 off, 1 acc, 2 run
} mrp_body_state_t;

mrp_can_frame_t mrp_frame_body(mrp_body_state_t state);

/// Four wheel pressures in kPa.
mrp_can_frame_t mrp_frame_tpms(float fl, float fr, float rl, float rr);

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
