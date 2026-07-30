#include "merope_frames.h"

// OBD-II PID codes used as signal ids (shared vocabulary with the Swift side).
#define SIG_LOAD 0x04
#define SIG_COOLANT 0x05
#define SIG_MAP 0x0B
#define SIG_RPM 0x0C
#define SIG_SPEED 0x0D
#define SIG_INTAKE 0x0F
#define SIG_THROTTLE 0x11
#define SIG_FUEL 0x2F
#define SIG_VOLTAGE 0x42

static uint8_t clamp_u8(float v, float lo, float hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (uint8_t)(v + 0.5f);
}

static uint16_t clamp_u16(float v, float hi) {
    if (v < 0) v = 0;
    if (v > hi) v = hi;
    return (uint16_t)(v + 0.5f);
}

mrp_can_frame_t mrp_frame_telem_a(float rpm, float speed_kmh, float coolant_c,
                                  float throttle_pct, float load_pct) {
    mrp_can_frame_t f = {.id = MRP_ID_TELEM_A, .len = 6, .data = {0}};
    uint16_t rpm_q = clamp_u16(rpm * 4.0f, 65535.0f);  // 0.25 rpm resolution
    f.data[0] = (uint8_t)(rpm_q & 0xFF);
    f.data[1] = (uint8_t)(rpm_q >> 8);
    f.data[2] = clamp_u8(speed_kmh, 0, 255);
    f.data[3] = clamp_u8(coolant_c + 40.0f, 0, 255);  // OBD offset encoding
    f.data[4] = clamp_u8(throttle_pct, 0, 100);
    f.data[5] = clamp_u8(load_pct, 0, 100);
    return f;
}

mrp_can_frame_t mrp_frame_telem_b(float voltage, float intake_c, float fuel_pct,
                                  float map_kpa) {
    mrp_can_frame_t f = {.id = MRP_ID_TELEM_B, .len = 5, .data = {0}};
    uint16_t mv = clamp_u16(voltage * 1000.0f, 65535.0f);
    f.data[0] = (uint8_t)(mv & 0xFF);
    f.data[1] = (uint8_t)(mv >> 8);
    f.data[2] = clamp_u8(intake_c + 40.0f, 0, 255);
    f.data[3] = clamp_u8(fuel_pct, 0, 100);
    f.data[4] = clamp_u8(map_kpa, 0, 255);
    return f;
}

mrp_can_frame_t mrp_frame_body(mrp_body_state_t st) {
    mrp_can_frame_t f = {.id = MRP_ID_BODY, .len = 3, .data = {0}};
    // Byte 0: latch bits. Byte 1: belts. Byte 2: gear (low nibble) +
    // ignition (high nibble) — a plausible packing, not the Forester's real
    // one. Recon replaces this decode, not the pipeline above it.
    f.data[0] = (uint8_t)((st.gate_open ? 0x01 : 0) | (st.door_fl ? 0x02 : 0) |
                          (st.door_fr ? 0x04 : 0) | (st.door_rl ? 0x08 : 0) |
                          (st.door_rr ? 0x10 : 0));
    f.data[1] = (uint8_t)((st.belt_driver ? 0x01 : 0) | (st.belt_passenger ? 0x02 : 0));
    f.data[2] = (uint8_t)((st.gear & 0x0F) | ((st.ignition & 0x0F) << 4));
    return f;
}

mrp_can_frame_t mrp_frame_tpms(float fl, float fr, float rl, float rr) {
    mrp_can_frame_t f = {.id = MRP_ID_TPMS, .len = 4, .data = {0}};
    // kPa in half-unit steps: 0–510 kPa covers anything a tire should see.
    f.data[0] = clamp_u8(fl * 0.5f, 0, 255);
    f.data[1] = clamp_u8(fr * 0.5f, 0, 255);
    f.data[2] = clamp_u8(rl * 0.5f, 0, 255);
    f.data[3] = clamp_u8(rr * 0.5f, 0, 255);
    return f;
}

mrp_can_frame_t mrp_frame_status(bool mil_on, uint8_t dtc_count) {
    mrp_can_frame_t f = {.id = MRP_ID_STATUS, .len = 2, .data = {0}};
    f.data[0] = mil_on ? 1 : 0;
    f.data[1] = dtc_count;
    return f;
}

static size_t emit(mrp_sample_t *out, size_t i, size_t max, uint32_t ms,
                   uint16_t signal, float value) {
    if (i < max) {
        out[i].ms = ms;
        out[i].signal = signal;
        out[i].value = value;
    }
    return i + 1;
}

size_t mrp_frame_decode(const mrp_can_frame_t *frame, uint32_t now_ms,
                        mrp_sample_t *out, size_t out_max) {
    size_t n = 0;
    switch (frame->id) {
    case MRP_ID_TELEM_A: {
        if (frame->len < 6) return 0;
        uint16_t rpm_q = (uint16_t)(frame->data[0] | (frame->data[1] << 8));
        n = emit(out, n, out_max, now_ms, SIG_RPM, (float)rpm_q / 4.0f);
        n = emit(out, n, out_max, now_ms, SIG_SPEED, (float)frame->data[2]);
        n = emit(out, n, out_max, now_ms, SIG_COOLANT, (float)frame->data[3] - 40.0f);
        n = emit(out, n, out_max, now_ms, SIG_THROTTLE, (float)frame->data[4]);
        n = emit(out, n, out_max, now_ms, SIG_LOAD, (float)frame->data[5]);
        break;
    }
    case MRP_ID_TELEM_B: {
        if (frame->len < 5) return 0;
        uint16_t mv = (uint16_t)(frame->data[0] | (frame->data[1] << 8));
        n = emit(out, n, out_max, now_ms, SIG_VOLTAGE, (float)mv / 1000.0f);
        n = emit(out, n, out_max, now_ms, SIG_INTAKE, (float)frame->data[2] - 40.0f);
        n = emit(out, n, out_max, now_ms, SIG_FUEL, (float)frame->data[3]);
        n = emit(out, n, out_max, now_ms, SIG_MAP, (float)frame->data[4]);
        break;
    }
    case MRP_ID_BODY: {
        if (frame->len < 3) return 0;
        uint8_t latches = frame->data[0];
        uint8_t belts = frame->data[1];
        n = emit(out, n, out_max, now_ms, MRP_SIG_GATE, (latches & 0x01) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_DOOR_FL, (latches & 0x02) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_DOOR_FR, (latches & 0x04) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_DOOR_RL, (latches & 0x08) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_DOOR_RR, (latches & 0x10) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_BELT_DRIVER, (belts & 0x01) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_BELT_PASSENGER, (belts & 0x02) ? 1.0f : 0.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_GEAR, (float)(frame->data[2] & 0x0F));
        n = emit(out, n, out_max, now_ms, MRP_SIG_IGNITION, (float)(frame->data[2] >> 4));
        break;
    }
    case MRP_ID_TPMS: {
        if (frame->len < 4) return 0;
        n = emit(out, n, out_max, now_ms, MRP_SIG_TPMS_FL, (float)frame->data[0] * 2.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_TPMS_FR, (float)frame->data[1] * 2.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_TPMS_RL, (float)frame->data[2] * 2.0f);
        n = emit(out, n, out_max, now_ms, MRP_SIG_TPMS_RR, (float)frame->data[3] * 2.0f);
        break;
    }
    default:
        return 0;
    }
    return n <= out_max ? n : out_max;
}

bool mrp_frame_status_decode(const mrp_can_frame_t *frame, bool *mil_on,
                             uint8_t *dtc_count) {
    if (frame->id != MRP_ID_STATUS || frame->len < 2) {
        return false;
    }
    *mil_on = frame->data[0] != 0;
    *dtc_count = frame->data[1];
    return true;
}
