// Merope — the black box, on real silicon.
//
// Listens to the bus (never transmits — LISTEN_ONLY is enforced in the TWAI
// controller, not just in our code), decodes frames into the rolling ring,
// watches MIL/DTC state for a rising edge, and on a fault captures the
// pre/post window and serializes it to the event format.
//
// Everything interesting here — ring, watcher, frame codec, event encoding —
// is the same merope_core C that has 19 tests passing on the host.
#ifdef MRP_APP_MEROPE

#include <stdio.h>
#include <string.h>

#include "driver/twai.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "board_led.h"
#include "merope_event.h"
#include "merope_frames.h"
#include "merope_ring.h"
#include "merope_watch.h"

static const char *TAG = "merope";

// Board identity: violet — the star that hides. (Electra wears amber.)
/// Violet idle, brighter while receiving, red while a fault capture runs.
static void led_set(uint8_t r, uint8_t g, uint8_t b) {
    board_led_set(r, g, b);
}

// Bench-sized: 4096 samples is ~90 s at the fake car's rate, comfortably in
// internal RAM. The car build moves this to PSRAM and lengthens the windows.
#define RING_CAPACITY 4096
#define WINDOW_PRE_MS 5000
#define WINDOW_POST_MS 3000
#define MAX_EVENT_SAMPLES 1024

static mrp_sample_t ring_storage[RING_CAPACITY];
static mrp_ring_t ring;
static mrp_watch_t watch;

static mrp_sample_t event_samples[MAX_EVENT_SAMPLES];
static uint8_t event_buffer[MRP_EVENT_HEADER_SIZE + MAX_EVENT_SAMPLES * MRP_EVENT_SAMPLE_SIZE];

static bool last_mil = false;
static uint8_t last_dtc_count = 0;
static uint32_t frames_seen = 0;

static uint32_t now_ms(void) {
    return (uint32_t)(esp_timer_get_time() / 1000);
}

/// A fault's post-window has elapsed: cut the slice out of the ring and
/// serialize it. On the car this write goes to LittleFS and later syncs to
/// Celaeno over BLE; on the bench, printing it is the proof.
static void finalize_event(void) {
    uint32_t start = mrp_watch_window_start(&watch);
    size_t count = mrp_ring_window(&ring, start, event_samples, MAX_EVENT_SAMPLES);

    mrp_event_t event = {
        .trigger_ms = watch.trigger_ms,
        .mil_on = last_mil,
        .dtc_count = last_dtc_count,
        .sample_count = (uint16_t)count,
        .samples = event_samples,
    };
    size_t bytes = mrp_event_encode(&event, event_buffer, sizeof(event_buffer));

    ESP_LOGI(TAG, "──── EVENT CAPTURED ────");
    ESP_LOGI(TAG, "  trigger at %lu ms, window %lu..%lu",
             (unsigned long)watch.trigger_ms, (unsigned long)start,
             (unsigned long)(watch.trigger_ms + WINDOW_POST_MS));
    ESP_LOGI(TAG, "  %u samples, %u bytes encoded", (unsigned)count, (unsigned)bytes);

    // What the movie actually shows: first/last value of a couple of signals.
    for (uint16_t sig = 0; sig < 2; sig++) {
        uint16_t want = sig == 0 ? 0x0C : 0x05;  // rpm, coolant
        const char *name = sig == 0 ? "rpm" : "coolant";
        float first = 0, last = 0;
        bool found = false;
        for (size_t i = 0; i < count; i++) {
            if (event_samples[i].signal != want) continue;
            if (!found) { first = event_samples[i].value; found = true; }
            last = event_samples[i].value;
        }
        if (found) {
            ESP_LOGI(TAG, "  %-8s %.0f → %.0f across the window", name, first, last);
        }
    }
    ESP_LOGI(TAG, "────────────────────────");
}

void app_main(void) {
    mrp_ring_init(&ring, ring_storage, RING_CAPACITY);
    mrp_watch_init(&watch, WINDOW_PRE_MS, WINDOW_POST_MS);
    board_led_init();
    led_set(22, 17, 28);  // dim violet: alive, no traffic yet

    twai_general_config_t general =
        TWAI_GENERAL_CONFIG_DEFAULT(MRP_TWAI_TX, MRP_TWAI_RX, TWAI_MODE_LISTEN_ONLY);
    twai_timing_config_t timing = TWAI_TIMING_CONFIG_500KBITS();
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    ESP_ERROR_CHECK(twai_driver_install(&general, &timing, &filter));
    ESP_ERROR_CHECK(twai_start());

    ESP_LOGI(TAG, "Merope listening at 500 kbit/s (LISTEN_ONLY — cannot transmit).");
    ESP_LOGI(TAG, "Ring: %d samples. Window: %d ms pre / %d ms post.",
             RING_CAPACITY, WINDOW_PRE_MS, WINDOW_POST_MS);

    mrp_sample_t decoded[8];
    uint32_t last_report = 0;

    while (1) {
        twai_message_t msg;
        if (twai_receive(&msg, pdMS_TO_TICKS(100)) == ESP_OK) {
            frames_seen++;
            mrp_can_frame_t frame = {
                .id = (uint16_t)msg.identifier,
                .len = msg.data_length_code,
            };
            memcpy(frame.data, msg.data, msg.data_length_code);

            uint32_t t = now_ms();
            bool mil;
            uint8_t count;
            if (mrp_frame_status_decode(&frame, &mil, &count)) {
                last_mil = mil;
                last_dtc_count = count;
                if (mrp_watch_feed(&watch, t, mil, count)) {
                    ESP_LOGW(TAG, "FAULT detected at %lu ms — capturing %d ms of context",
                             (unsigned long)t, WINDOW_POST_MS);
                    led_set(60, 0, 0);  // capturing
                }
            } else {
                size_t n = mrp_frame_decode(&frame, t, decoded, 8);
                for (size_t i = 0; i < n; i++) {
                    mrp_ring_push(&ring, decoded[i]);
                }
            }
        }

        if (mrp_watch_capture_due(&watch, now_ms())) {
            finalize_event();
            led_set(45, 34, 58);
        }

        uint32_t t = now_ms();
        if (t - last_report >= 5000) {
            last_report = t;
            // Bright violet once traffic is flowing, dim when the bus is quiet.
            led_set(frames_seen > 0 ? 45 : 22, frames_seen > 0 ? 34 : 17,
                    frames_seen > 0 ? 58 : 28);
            ESP_LOGI(TAG, "%lu frames seen, %u samples buffered, MIL %d",
                     (unsigned long)frames_seen, (unsigned)mrp_ring_count(&ring), last_mil);

            // A receiver that sees nothing and reports nothing is ambiguous:
            // an idle bus and a dead receive path look identical. The error
            // counters tell them apart.
            twai_status_info_t status;
            if (twai_get_status_info(&status) == ESP_OK) {
                const char *state = status.state == TWAI_STATE_RUNNING ? "RUNNING"
                                    : status.state == TWAI_STATE_BUS_OFF ? "BUS_OFF"
                                    : status.state == TWAI_STATE_RECOVERING ? "RECOVERING"
                                                                            : "STOPPED";
                ESP_LOGI(TAG, "  bus %s | rx_err %lu | rx_missed %lu | queued_rx %lu",
                         state, (unsigned long)status.rx_error_counter,
                         (unsigned long)status.rx_missed_count,
                         (unsigned long)status.msgs_to_rx);
                if (frames_seen == 0 && status.rx_error_counter == 0) {
                    ESP_LOGW(TAG, "  Zero frames AND zero errors: the controller sees an idle");
                    ESP_LOGW(TAG, "  bus. Check this board's transceiver 3V3/GND and the");
                    ESP_LOGW(TAG, "  CRX→GPIO5 wire — an unpowered transceiver reads idle.");
                }
            }
        }
    }
}

#endif  // MRP_APP_MEROPE
