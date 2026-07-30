// Electra-on-a-wire: the fake Forester, in silicon.
//
// Transmits plausible telemetry frames plus a MIL/DTC status frame onto the
// desk bus, so Merope's firmware can be developed and demonstrated without a
// car. Press the BOOT button to trip a fault; press again to clear it.
//
// Transmits in NO_ACK mode on purpose: Merope listens in LISTEN_ONLY and
// therefore never acknowledges, which on a normal CAN node would fail every
// transmission. NO_ACK lets a two-node bench work while keeping Merope's
// behavior identical to how it must behave in the car.
#ifdef MRP_APP_ELECTRA

#include <stdio.h>

#include "driver/gpio.h"
#include "driver/twai.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "merope_frames.h"

static const char *TAG = "electra";

#define BOOT_BUTTON GPIO_NUM_0
#define TX_PERIOD_MS 100  // 10 Hz telemetry
#define STATUS_EVERY 5    // status frame every 5th tick (2 Hz)

static bool mil_on = false;
static uint8_t dtc_count = 0;

/// A simple repeating drive cycle so there's motion in the ring: idle,
/// pull, cruise, back to idle, every 40 seconds.
static void drive_cycle(uint32_t ms, float *rpm, float *speed, float *coolant,
                        float *throttle, float *load) {
    uint32_t phase = (ms / 1000) % 40;
    float t;
    if (phase < 10) {           // idle
        t = 0.0f;
    } else if (phase < 20) {    // pull
        t = 0.75f;
    } else if (phase < 32) {    // cruise
        t = 0.25f;
    } else {                    // coast down
        t = 0.0f;
    }
    *throttle = t * 100.0f;
    *rpm = 650.0f + t * 5000.0f;
    *speed = t * 120.0f;
    *load = 15.0f + t * 70.0f;
    // Warms toward 90 C over the first few minutes, then holds.
    float warm = (float)ms / 180000.0f;
    *coolant = 22.0f + (warm > 1.0f ? 1.0f : warm) * 68.0f;
}

static void send(mrp_can_frame_t frame) {
    twai_message_t msg = {
        .identifier = frame.id,
        .data_length_code = frame.len,
    };
    for (int i = 0; i < frame.len; i++) {
        msg.data[i] = frame.data[i];
    }
    esp_err_t err = twai_transmit(&msg, pdMS_TO_TICKS(50));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "tx 0x%03X failed: %s", frame.id, esp_err_to_name(err));
    }
}

/// Debounced BOOT button: toggles the fault state.
static void poll_button(void) {
    static bool was_down = false;
    bool down = gpio_get_level(BOOT_BUTTON) == 0;
    if (down && !was_down) {
        if (mil_on) {
            mil_on = false;
            dtc_count = 0;
            ESP_LOGI(TAG, "fault CLEARED (MIL off)");
        } else {
            mil_on = true;
            dtc_count++;
            ESP_LOGI(TAG, "fault INJECTED (MIL on, %d code(s))", dtc_count);
        }
    }
    was_down = down;
}

void app_main(void) {
    gpio_config_t button = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&button));

    twai_general_config_t general =
        TWAI_GENERAL_CONFIG_DEFAULT(MRP_TWAI_TX, MRP_TWAI_RX, TWAI_MODE_NO_ACK);
    twai_timing_config_t timing = TWAI_TIMING_CONFIG_500KBITS();
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    ESP_ERROR_CHECK(twai_driver_install(&general, &timing, &filter));
    ESP_ERROR_CHECK(twai_start());

    ESP_LOGI(TAG, "Electra-on-a-wire up at 500 kbit/s. BOOT button = inject/clear fault.");

    uint32_t tick = 0;
    while (1) {
        poll_button();

        uint32_t ms = (uint32_t)(esp_timer_get_time() / 1000);
        float rpm, speed, coolant, throttle, load;
        drive_cycle(ms, &rpm, &speed, &coolant, &throttle, &load);

        send(mrp_frame_telem_a(rpm, speed, coolant, throttle, load));
        send(mrp_frame_telem_b(13.9f, 31.0f, 74.0f, 25.0f + throttle * 0.76f));
        if (tick % STATUS_EVERY == 0) {
            send(mrp_frame_status(mil_on, dtc_count));
        }
        if (tick % 50 == 0) {
            ESP_LOGI(TAG, "rpm %.0f  speed %.0f  coolant %.0f  mil %d",
                     rpm, speed, coolant, mil_on);
        }

        tick++;
        vTaskDelay(pdMS_TO_TICKS(TX_PERIOD_MS));
    }
}

#endif  // MRP_APP_ELECTRA
