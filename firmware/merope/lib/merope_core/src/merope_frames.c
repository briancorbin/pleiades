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
