#include <unity.h>

#include "merope_ring.h"
#include "merope_watch.h"

void setUp(void) {}
void tearDown(void) {}

// --- ring buffer ---

static void test_count_grows_then_caps(void) {
    mrp_sample_t storage[4];
    mrp_ring_t ring;
    mrp_ring_init(&ring, storage, 4);

    TEST_ASSERT_EQUAL_size_t(0, mrp_ring_count(&ring));
    for (uint32_t i = 0; i < 6; i++) {
        mrp_ring_push(&ring, (mrp_sample_t){.ms = i, .signal = 1, .value = 0});
    }
    TEST_ASSERT_EQUAL_size_t(4, mrp_ring_count(&ring));
}

static void test_wraparound_overwrites_oldest(void) {
    mrp_sample_t storage[4];
    mrp_ring_t ring;
    mrp_ring_init(&ring, storage, 4);

    for (uint32_t i = 0; i < 6; i++) {
        mrp_ring_push(&ring, (mrp_sample_t){.ms = i * 100, .signal = 1, .value = (float)i});
    }
    mrp_sample_t out[8];
    size_t n = mrp_ring_window(&ring, 0, out, 8);
    TEST_ASSERT_EQUAL_size_t(4, n);
    TEST_ASSERT_EQUAL_UINT32(200, out[0].ms);  // 0 and 100 were overwritten
    TEST_ASSERT_EQUAL_UINT32(500, out[3].ms);  // oldest-first ordering
}

static void test_window_filters_by_time(void) {
    mrp_sample_t storage[8];
    mrp_ring_t ring;
    mrp_ring_init(&ring, storage, 8);

    for (uint32_t i = 0; i < 8; i++) {
        mrp_ring_push(&ring, (mrp_sample_t){.ms = i * 1000, .signal = 1, .value = 0});
    }
    mrp_sample_t out[8];
    size_t n = mrp_ring_window(&ring, 5000, out, 8);
    TEST_ASSERT_EQUAL_size_t(3, n);
    TEST_ASSERT_EQUAL_UINT32(5000, out[0].ms);
}

static void test_window_respects_out_max(void) {
    mrp_sample_t storage[8];
    mrp_ring_t ring;
    mrp_ring_init(&ring, storage, 8);

    for (uint32_t i = 0; i < 8; i++) {
        mrp_ring_push(&ring, (mrp_sample_t){.ms = i, .signal = 1, .value = 0});
    }
    mrp_sample_t out[2];
    size_t n = mrp_ring_window(&ring, 0, out, 2);
    TEST_ASSERT_EQUAL_size_t(2, n);
    TEST_ASSERT_EQUAL_UINT32(0, out[0].ms);
}

// --- fault watcher ---

static void test_first_observation_is_baseline_not_event(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    // Car boots with the MIL already on: old news, not an event.
    TEST_ASSERT_FALSE(mrp_watch_feed(&watch, 0, true, 2));
    TEST_ASSERT_FALSE(mrp_watch_feed(&watch, 1000, true, 2));
}

static void test_mil_rising_edge_fires(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    TEST_ASSERT_FALSE(mrp_watch_feed(&watch, 0, false, 0));
    TEST_ASSERT_TRUE(mrp_watch_feed(&watch, 5000, true, 1));
}

static void test_count_increase_fires_even_with_mil_already_on(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    mrp_watch_feed(&watch, 0, true, 1);  // baseline: one old code
    TEST_ASSERT_TRUE(mrp_watch_feed(&watch, 5000, true, 2));  // a second sets
}

static void test_no_refire_while_capturing(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    mrp_watch_feed(&watch, 0, false, 0);
    TEST_ASSERT_TRUE(mrp_watch_feed(&watch, 1000, true, 1));
    TEST_ASSERT_FALSE(mrp_watch_feed(&watch, 1500, true, 2));  // mid-capture
}

static void test_capture_due_after_post_window_then_rearms(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    mrp_watch_feed(&watch, 0, false, 0);
    mrp_watch_feed(&watch, 1000, true, 1);

    TEST_ASSERT_FALSE(mrp_watch_capture_due(&watch, 2000));  // 1s in
    TEST_ASSERT_TRUE(mrp_watch_capture_due(&watch, 3000));   // post elapsed
    TEST_ASSERT_FALSE(mrp_watch_capture_due(&watch, 4000));  // fires once

    // Cleared then a fresh fault: fires again.
    mrp_watch_feed(&watch, 5000, false, 0);
    TEST_ASSERT_TRUE(mrp_watch_feed(&watch, 6000, true, 1));
}

static void test_window_start_clamps_at_boot(void) {
    mrp_watch_t watch;
    mrp_watch_init(&watch, 60000, 2000);
    mrp_watch_feed(&watch, 0, false, 0);
    mrp_watch_feed(&watch, 500, true, 1);  // fault 500ms after boot
    TEST_ASSERT_EQUAL_UINT32(0, mrp_watch_window_start(&watch));
}

// --- end to end on the desk ---

static void test_fault_extracts_pre_and_post_window(void) {
    mrp_sample_t storage[128];
    mrp_ring_t ring;
    mrp_ring_init(&ring, storage, 128);
    mrp_watch_t watch;
    mrp_watch_init(&watch, 3000, 2000);
    mrp_watch_feed(&watch, 0, false, 0);

    // One rpm sample per second; fault at t=95s; keep recording to t=97s.
    bool fired = false;
    for (uint32_t t = 0; t <= 97000; t += 1000) {
        mrp_ring_push(&ring, (mrp_sample_t){.ms = t, .signal = 0x0C, .value = 2000});
        if (t == 95000) {
            fired = mrp_watch_feed(&watch, t, true, 1);
        }
    }
    TEST_ASSERT_TRUE(fired);
    TEST_ASSERT_TRUE(mrp_watch_capture_due(&watch, 97000));

    mrp_sample_t event[16];
    size_t n = mrp_ring_window(&ring, mrp_watch_window_start(&watch), event, 16);
    TEST_ASSERT_EQUAL_size_t(6, n);  // 92s..97s inclusive
    TEST_ASSERT_EQUAL_UINT32(92000, event[0].ms);
    TEST_ASSERT_EQUAL_UINT32(97000, event[5].ms);
}

int main(void) {
    UNITY_BEGIN();
    RUN_TEST(test_count_grows_then_caps);
    RUN_TEST(test_wraparound_overwrites_oldest);
    RUN_TEST(test_window_filters_by_time);
    RUN_TEST(test_window_respects_out_max);
    RUN_TEST(test_first_observation_is_baseline_not_event);
    RUN_TEST(test_mil_rising_edge_fires);
    RUN_TEST(test_count_increase_fires_even_with_mil_already_on);
    RUN_TEST(test_no_refire_while_capturing);
    RUN_TEST(test_capture_due_after_post_window_then_rearms);
    RUN_TEST(test_window_start_clamps_at_boot);
    RUN_TEST(test_fault_extracts_pre_and_post_window);
    return UNITY_END();
}
