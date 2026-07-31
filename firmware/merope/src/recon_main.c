// Recon: the first-contact tool for a real car's bus.
//
// Merope's normal firmware decodes frame layouts we invented. Against an
// actual Forester those mean nothing, so this build does something simpler
// and far more useful: log every frame ID it sees, then tell you which bytes
// changed when you did something.
//
// The workflow that finds a signal in a few minutes:
//   1. sit with the ignition on, let the table fill
//   2. press BOOT — snapshots every frame's current bytes
//   3. do the thing (open the gate, unbuckle the belt, press the brake)
//   4. press BOOT again — reports exactly which IDs and which bytes moved
//
// LISTEN_ONLY throughout: the controller is electrically incapable of
// putting anything on the car's bus while we're still learning what's there.
#ifdef MRP_APP_RECON

#include <stdio.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/twai.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "board_led.h"

static const char *TAG = "recon";

#define BOOT_BUTTON GPIO_NUM_0
#define MAX_IDS 256

typedef struct {
    uint32_t id;
    uint8_t dlc;
    uint8_t data[8];
    uint8_t marked[8];
    uint32_t count;
    bool seen;
    bool changed_since_mark;
} frame_slot_t;

static frame_slot_t slots[MAX_IDS];
static size_t slot_count;
static bool marked;
static uint32_t total_frames;

static frame_slot_t *slot_for(uint32_t id) {
    for (size_t i = 0; i < slot_count; i++) {
        if (slots[i].id == id) return &slots[i];
    }
    if (slot_count >= MAX_IDS) return NULL;
    frame_slot_t *s = &slots[slot_count++];
    s->id = id;
    s->seen = true;
    return s;
}

/// Snapshot every frame's current bytes as the baseline.
static void take_mark(void) {
    for (size_t i = 0; i < slot_count; i++) {
        memcpy(slots[i].marked, slots[i].data, 8);
        slots[i].changed_since_mark = false;
    }
    marked = true;
    board_led_set(0, 0, 50);  // blue: baseline captured
    ESP_LOGW(TAG, "");
    ESP_LOGW(TAG, "═══ MARKED %u frame ids ═══", (unsigned)slot_count);
    ESP_LOGW(TAG, "Now do the thing — open the gate, unbuckle, press the brake.");
    ESP_LOGW(TAG, "Then press BOOT again to see what moved.");
    ESP_LOGW(TAG, "");
}

/// Report every frame whose bytes differ from the mark, with the specific
/// byte positions — those are the candidate signals.
static void report_changes(void) {
    ESP_LOGW(TAG, "");
    ESP_LOGW(TAG, "═══ CHANGED SINCE MARK ═══");
    int changed = 0;
    for (size_t i = 0; i < slot_count; i++) {
        frame_slot_t *s = &slots[i];
        if (!s->changed_since_mark) continue;
        changed++;

        char before[32] = {0}, after[32] = {0}, marks[32] = {0};
        for (int b = 0; b < s->dlc; b++) {
            sprintf(before + b * 3, "%02X ", s->marked[b]);
            sprintf(after + b * 3, "%02X ", s->data[b]);
            // Point at the bytes that actually moved.
            sprintf(marks + b * 3, "%s ", s->marked[b] != s->data[b] ? "^^" : "  ");
        }
        ESP_LOGW(TAG, "  0x%03X  was: %s", (unsigned)s->id, before);
        ESP_LOGW(TAG, "         now: %s", after);
        ESP_LOGW(TAG, "              %s", marks);
    }
    if (changed == 0) {
        ESP_LOGW(TAG, "  nothing changed — is the ignition on? did the action register?");
    } else {
        ESP_LOGW(TAG, "  %d frame id(s) moved. Those are your candidates.", changed);
    }
    ESP_LOGW(TAG, "═══════════════════════════");
    ESP_LOGW(TAG, "");
    marked = false;
    board_led_set(45, 34, 58);
}

static void poll_button(void) {
    static bool was_down = false;
    bool down = gpio_get_level(BOOT_BUTTON) == 0;
    if (down && !was_down) {
        if (marked) {
            report_changes();
        } else {
            take_mark();
        }
    }
    was_down = down;
}

/// The full inventory: every id seen and how often. Run this first to learn
/// what the bus even looks like.
static void dump_inventory(void) {
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "── %u ids, %lu frames total ──",
             (unsigned)slot_count, (unsigned long)total_frames);
    for (size_t i = 0; i < slot_count; i++) {
        frame_slot_t *s = &slots[i];
        char bytes[32] = {0};
        for (int b = 0; b < s->dlc; b++) {
            sprintf(bytes + b * 3, "%02X ", s->data[b]);
        }
        ESP_LOGI(TAG, "  0x%03X  dlc %d  x%-6lu  %s",
                 (unsigned)s->id, s->dlc, (unsigned long)s->count, bytes);
    }
}

void app_main(void) {
    gpio_config_t button = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&button);
    board_led_init();
    board_led_set(45, 34, 58);

    twai_general_config_t general =
        TWAI_GENERAL_CONFIG_DEFAULT(MRP_TWAI_TX, MRP_TWAI_RX, TWAI_MODE_LISTEN_ONLY);
    twai_timing_config_t timing = TWAI_TIMING_CONFIG_500KBITS();
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    ESP_ERROR_CHECK(twai_driver_install(&general, &timing, &filter));
    ESP_ERROR_CHECK(twai_start());

    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "RECON — listen-only at 500 kbit/s. Cannot transmit.");
    ESP_LOGI(TAG, "BOOT once = mark baseline. BOOT again = show what changed.");
    ESP_LOGI(TAG, "");

    uint32_t last_dump = 0;
    while (1) {
        poll_button();

        twai_message_t msg;
        if (twai_receive(&msg, pdMS_TO_TICKS(20)) == ESP_OK) {
            total_frames++;
            frame_slot_t *s = slot_for(msg.identifier);
            if (s) {
                s->dlc = msg.data_length_code;
                s->count++;
                if (marked && memcmp(s->data, msg.data, msg.data_length_code) != 0) {
                    // Compare against the mark, not the previous frame —
                    // counters and rolling values change constantly.
                    if (memcmp(s->marked, msg.data, msg.data_length_code) != 0) {
                        s->changed_since_mark = true;
                    }
                }
                memcpy(s->data, msg.data, msg.data_length_code);
            }
        }

        uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
        if (!marked && now - last_dump >= 10000) {
            last_dump = now;
            if (slot_count == 0) {
                ESP_LOGW(TAG, "No frames yet. Check: ignition on, CAN-H→pin 6,");
                ESP_LOGW(TAG, "CAN-L→pin 14, ground, and the 120Ω removed from");
                ESP_LOGW(TAG, "this transceiver (the car's bus is already terminated).");
                board_led_set(50, 0, 0);
            } else {
                dump_inventory();
                board_led_set(45, 34, 58);
            }
        }
    }
}

#endif  // MRP_APP_RECON
