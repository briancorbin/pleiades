#include <unity.h>

#include "merope_event.h"
#include "merope_frames.h"
#include "merope_watch.h"

void setUp(void) {}
void tearDown(void) {}

// --- event serialization ---

static void test_event_round_trip(void) {
    mrp_sample_t samples[3] = {
        {.ms = 92000, .signal = 0x0C, .value = 3862.5f},
        {.ms = 93000, .signal = 0x0D, .value = 88.0f},
        {.ms = 94000, .signal = 0x05, .value = -12.0f},
    };
    mrp_event_t event = {
        .trigger_ms = 95000, .mil_on = true, .dtc_count = 2,
        .sample_count = 3, .samples = samples,
    };

    uint8_t buf[128];
    size_t written = mrp_event_encode(&event, buf, sizeof(buf));
    TEST_ASSERT_EQUAL_size_t(13 + 3 * 10, written);

    mrp_event_t decoded;
    mrp_sample_t out[8];
    TEST_ASSERT_TRUE(mrp_event_decode(buf, written, &decoded, out, 8));
    TEST_ASSERT_EQUAL_UINT32(95000, decoded.trigger_ms);
    TEST_ASSERT_TRUE(decoded.mil_on);
    TEST_ASSERT_EQUAL_UINT8(2, decoded.dtc_count);
    TEST_ASSERT_EQUAL_UINT16(3, decoded.sample_count);
    TEST_ASSERT_EQUAL_UINT32(92000, decoded.samples[0].ms);
    TEST_ASSERT_EQUAL_UINT16(0x0C, decoded.samples[0].signal);
    TEST_ASSERT_EQUAL_FLOAT(3862.5f, decoded.samples[0].value);
    TEST_ASSERT_EQUAL_FLOAT(-12.0f, decoded.samples[2].value);
}

static void test_event_encode_fails_when_buffer_small(void) {
    mrp_sample_t s = {.ms = 0, .signal = 1, .value = 1};
    mrp_event_t event = {.trigger_ms = 0, .mil_on = false, .dtc_count = 0,
                         .sample_count = 1, .samples = &s};
    uint8_t buf[16];  // needs 23
    TEST_ASSERT_EQUAL_size_t(0, mrp_event_encode(&event, buf, sizeof(buf)));
}

static void test_event_decode_rejects_bad_magic_and_truncation(void) {
    mrp_sample_t s = {.ms = 0, .signal = 1, .value = 1};
    mrp_event_t event = {.trigger_ms = 7, .mil_on = true, .dtc_count = 1,
                         .sample_count = 1, .samples = &s};
    uint8_t buf[64];
    size_t written = mrp_event_encode(&event, buf, sizeof(buf));

    mrp_event_t decoded;
    mrp_sample_t out[4];
    TEST_ASSERT_TRUE(mrp_event_decode(buf, written, &decoded, out, 4));
    TEST_ASSERT_FALSE(mrp_event_decode(buf, written - 1, &decoded, out, 4));
    buf[0] = 'X';
    TEST_ASSERT_FALSE(mrp_event_decode(buf, written, &decoded, out, 4));
}

// --- frame codec ---

static void test_telem_a_round_trip(void) {
    mrp_can_frame_t f = mrp_frame_telem_a(3862.5f, 88.0f, 91.0f, 47.0f, 62.0f);
    TEST_ASSERT_EQUAL_UINT16(MRP_ID_TELEM_A, f.id);

    mrp_sample_t out[8];
    size_t n = mrp_frame_decode(&f, 1000, out, 8);
    TEST_ASSERT_EQUAL_size_t(5, n);
    TEST_ASSERT_EQUAL_UINT16(0x0C, out[0].signal);
    TEST_ASSERT_FLOAT_WITHIN(0.25f, 3862.5f, out[0].value);   // rpm quantized
    TEST_ASSERT_EQUAL_FLOAT(88.0f, out[1].value);              // speed
    TEST_ASSERT_EQUAL_FLOAT(91.0f, out[2].value);              // coolant
    TEST_ASSERT_EQUAL_FLOAT(47.0f, out[3].value);              // throttle
    TEST_ASSERT_EQUAL_FLOAT(62.0f, out[4].value);              // load
    TEST_ASSERT_EQUAL_UINT32(1000, out[0].ms);
}

static void test_telem_b_round_trip(void) {
    mrp_can_frame_t f = mrp_frame_telem_b(13.9f, 31.0f, 74.0f, 33.0f);
    mrp_sample_t out[8];
    size_t n = mrp_frame_decode(&f, 5, out, 8);
    TEST_ASSERT_EQUAL_size_t(4, n);
    TEST_ASSERT_EQUAL_UINT16(0x42, out[0].signal);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 13.9f, out[0].value);
    TEST_ASSERT_EQUAL_FLOAT(31.0f, out[1].value);
}

static void test_negative_coolant_survives_offset_encoding(void) {
    mrp_can_frame_t f = mrp_frame_telem_a(650, 0, -25.0f, 0, 15);
    mrp_sample_t out[8];
    mrp_frame_decode(&f, 0, out, 8);
    TEST_ASSERT_EQUAL_FLOAT(-25.0f, out[2].value);
}

static void test_unknown_frame_decodes_to_nothing(void) {
    mrp_can_frame_t f = {.id = 0x7DF, .len = 8, .data = {0}};
    mrp_sample_t out[8];
    TEST_ASSERT_EQUAL_size_t(0, mrp_frame_decode(&f, 0, out, 8));
}

static void test_status_frame_feeds_the_watcher(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);

    bool mil = false;
    uint8_t count = 0;
    mrp_can_frame_t healthy = mrp_frame_status(false, 0);
    TEST_ASSERT_TRUE(mrp_frame_status_decode(&healthy, &mil, &count));
    TEST_ASSERT_FALSE(mrp_watch_feed(&watch, 0, mil, count));  // baseline

    mrp_can_frame_t fault = mrp_frame_status(true, 1);
    TEST_ASSERT_TRUE(mrp_frame_status_decode(&fault, &mil, &count));
    TEST_ASSERT_TRUE(mrp_watch_feed(&watch, 5000, mil, count));  // fires

    mrp_can_frame_t telem = mrp_frame_telem_a(650, 0, 20, 0, 15);
    TEST_ASSERT_FALSE(mrp_frame_status_decode(&telem, &mil, &count));
}

static void test_body_frame_round_trip(void) {
    mrp_body_state_t st = {
        .gate_open = true, .door_fl = false, .door_fr = true,
        .door_rl = false, .door_rr = false,
        .belt_driver = true, .belt_passenger = false,
        .gear = 3, .ignition = 2,
    };
    mrp_can_frame_t f = mrp_frame_body(st);
    TEST_ASSERT_EQUAL_UINT16(MRP_ID_BODY, f.id);

    mrp_sample_t out[16];
    size_t n = mrp_frame_decode(&f, 100, out, 16);
    TEST_ASSERT_EQUAL_size_t(9, n);

    float gate = -1, door_fr = -1, belt_d = -1, gear = -1;
    for (size_t i = 0; i < n; i++) {
        if (out[i].signal == MRP_SIG_GATE) gate = out[i].value;
        if (out[i].signal == MRP_SIG_DOOR_FR) door_fr = out[i].value;
        if (out[i].signal == MRP_SIG_BELT_DRIVER) belt_d = out[i].value;
        if (out[i].signal == MRP_SIG_GEAR) gear = out[i].value;
    }
    TEST_ASSERT_EQUAL_FLOAT(1.0f, gate);
    TEST_ASSERT_EQUAL_FLOAT(1.0f, door_fr);
    TEST_ASSERT_EQUAL_FLOAT(1.0f, belt_d);
    TEST_ASSERT_EQUAL_FLOAT(3.0f, gear);
}

static void test_gate_closed_decodes_zero(void) {
    mrp_body_state_t st = {0};
    mrp_can_frame_t f = mrp_frame_body(st);
    mrp_sample_t out[16];
    mrp_frame_decode(&f, 0, out, 16);
    for (size_t i = 0; i < 16; i++) {
        if (out[i].signal == MRP_SIG_GATE) {
            TEST_ASSERT_EQUAL_FLOAT(0.0f, out[i].value);
            return;
        }
    }
    TEST_FAIL_MESSAGE("gate signal not emitted");
}

static void test_tpms_round_trip(void) {
    mrp_can_frame_t f = mrp_frame_tpms(220.0f, 218.0f, 150.0f, 221.0f);
    mrp_sample_t out[8];
    size_t n = mrp_frame_decode(&f, 0, out, 8);
    TEST_ASSERT_EQUAL_size_t(4, n);
    TEST_ASSERT_EQUAL_UINT16(MRP_SIG_TPMS_FL, out[0].signal);
    TEST_ASSERT_FLOAT_WITHIN(2.0f, 220.0f, out[0].value);
    TEST_ASSERT_FLOAT_WITHIN(2.0f, 150.0f, out[2].value);  // the low one
}

static void test_proprietary_signals_sit_above_pid_range(void) {
    // Standard PID codes are 0x00-0xFF; proprietary signals must not collide.
    TEST_ASSERT_TRUE(MRP_SIG_GATE > 0xFF);
    TEST_ASSERT_TRUE(MRP_SIG_TPMS_RR > 0xFF);
}

int main(void) {
    UNITY_BEGIN();
    RUN_TEST(test_body_frame_round_trip);
    RUN_TEST(test_gate_closed_decodes_zero);
    RUN_TEST(test_tpms_round_trip);
    RUN_TEST(test_proprietary_signals_sit_above_pid_range);
    RUN_TEST(test_event_round_trip);
    RUN_TEST(test_event_encode_fails_when_buffer_small);
    RUN_TEST(test_event_decode_rejects_bad_magic_and_truncation);
    RUN_TEST(test_telem_a_round_trip);
    RUN_TEST(test_telem_b_round_trip);
    RUN_TEST(test_negative_coolant_survives_offset_encoding);
    RUN_TEST(test_unknown_frame_decodes_to_nothing);
    RUN_TEST(test_status_frame_feeds_the_watcher);
    return UNITY_END();
}
