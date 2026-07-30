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

#include "board_led.h"
#include "merope_frames.h"

static const char *TAG = "electra";

// Board identity: amber = the fake car. (Merope wears violet.) Two identical
// dev boards on a desk are otherwise indistinguishable.
/// Amber when the bus is healthy, red when it isn't — glanceable status.
static void led_set(bool healthy) {
    if (healthy) {
        board_led_set(40, 18, 0);
    } else {
        board_led_set(40, 0, 0);
    }
}

#define BOOT_BUTTON GPIO_NUM_0
#define TX_PERIOD_MS 100  // 10 Hz telemetry
#define STATUS_EVERY 5    // status frame every 5th tick (2 Hz)

static bool mil_on = false;
static uint8_t dtc_count = 0;

// Scenarios — canned situations the bench can act out on demand. The BOOT
// button cycles them. This is why the simulator keeps earning its keep after
// the car exists: the car can't produce a fault at 11pm on request.
typedef enum {
    SCENARIO_NORMAL,     // everything buttoned up, nothing wrong
    SCENARIO_LUMBER,     // the origin story: gate open, driving anyway
    SCENARIO_FAULT,      // MIL sets mid-drive
    SCENARIO_SLOW_LEAK,  // one tire bleeding down over minutes
    SCENARIO_COUNT,
} scenario_t;

static scenario_t scenario = SCENARIO_NORMAL;
static uint32_t scenario_started_ms = 0;

static const char *scenario_name(scenario_t s) {
    switch (s) {
    case SCENARIO_LUMBER: return "LUMBER RUN (gate open)";
    case SCENARIO_FAULT: return "FAULT (MIL sets)";
    case SCENARIO_SLOW_LEAK: return "SLOW LEAK (RL tire)";
    default: return "NORMAL";
    }
}

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

static uint32_t tx_ok = 0;
static uint32_t tx_fail = 0;

static void send(mrp_can_frame_t frame) {
    twai_message_t msg = {
        .identifier = frame.id,
        .data_length_code = frame.len,
    };
    for (int i = 0; i < frame.len; i++) {
        msg.data[i] = frame.data[i];
    }
    if (twai_transmit(&msg, pdMS_TO_TICKS(50)) == ESP_OK) {
        tx_ok++;
    } else {
        tx_fail++;
    }
}

/// The controller's own view of the bus. Bus-off with a high TX error count
/// means the transmitted bits aren't coming back — wiring, not software.
static void report_bus(void) {
    twai_status_info_t status;
    if (twai_get_status_info(&status) != ESP_OK) {
        ESP_LOGE(TAG, "cannot read TWAI status");
        return;
    }
    const char *state = status.state == TWAI_STATE_RUNNING    ? "RUNNING"
                        : status.state == TWAI_STATE_BUS_OFF  ? "BUS_OFF"
                        : status.state == TWAI_STATE_RECOVERING ? "RECOVERING"
                                                                : "STOPPED";
    ESP_LOGI(TAG, "bus %s | tx ok %lu fail %lu | tx_err %lu rx_err %lu | queued %lu",
             state, (unsigned long)tx_ok, (unsigned long)tx_fail,
             (unsigned long)status.tx_error_counter,
             (unsigned long)status.rx_error_counter,
             (unsigned long)status.msgs_to_tx);
    led_set(status.state == TWAI_STATE_RUNNING && status.tx_error_counter < 96 &&
            status.rx_error_counter < 96);

    if (status.state == TWAI_STATE_BUS_OFF) {
        ESP_LOGW(TAG, "BUS_OFF — the controller sent bits and did not see them");
        ESP_LOGW(TAG, "  return on the wire. Check: transceiver 3V3/GND, GPIO5→CTX,");
        ESP_LOGW(TAG, "  GPIO4→CRX, CANH↔CANH, CANL↔CANL, and GND everywhere.");
        ESP_LOGW(TAG, "  Attempting recovery…");
        twai_initiate_recovery();
    } else if (status.state == TWAI_STATE_STOPPED) {
        twai_start();
    }
}

/// Debounced BOOT button: cycles scenarios.
static void poll_button(uint32_t now_ms) {
    static bool was_down = false;
    bool down = gpio_get_level(BOOT_BUTTON) == 0;
    if (down && !was_down) {
        scenario = (scenario_t)((scenario + 1) % SCENARIO_COUNT);
        scenario_started_ms = now_ms;
        mil_on = false;
        dtc_count = 0;
        ESP_LOGI(TAG, "▶ scenario: %s", scenario_name(scenario));
    }
    was_down = down;
}

/// Body state for the current scenario.
static mrp_body_state_t body_for_scenario(uint32_t elapsed_ms) {
    mrp_body_state_t st = {
        .gate_open = false,
        .belt_driver = true,
        .belt_passenger = false,
        .gear = 3,      // D
        .ignition = 2,  // run
    };
    if (scenario == SCENARIO_LUMBER) {
        // Gate goes up ~4 s in and stays up — strapped down, hauling.
        st.gate_open = elapsed_ms > 4000;
    }
    return st;
}

/// Tire pressures for the current scenario, kPa (~220 = 32 psi).
static void tpms_for_scenario(uint32_t elapsed_ms, float *fl, float *fr,
                              float *rl, float *rr) {
    *fl = 221.0f;
    *fr = 219.0f;
    *rl = 220.0f;
    *rr = 218.0f;
    if (scenario == SCENARIO_SLOW_LEAK) {
        // Rear-left bleeds ~1 kPa/s so a leak is watchable in a demo, not a
        // real-world rate.
        float dropped = (float)elapsed_ms / 1000.0f;
        *rl = 220.0f - dropped;
        if (*rl < 70.0f) *rl = 70.0f;
    }
}

void app_main(void) {
    gpio_config_t button = {
        .pin_bit_mask = 1ULL << BOOT_BUTTON,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&button));
    board_led_init();
    led_set(true);

    twai_general_config_t general =
        TWAI_GENERAL_CONFIG_DEFAULT(MRP_TWAI_TX, MRP_TWAI_RX, TWAI_MODE_NO_ACK);
    twai_timing_config_t timing = TWAI_TIMING_CONFIG_500KBITS();
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    ESP_ERROR_CHECK(twai_driver_install(&general, &timing, &filter));
    ESP_ERROR_CHECK(twai_start());

    ESP_LOGI(TAG, "Electra-on-a-wire up at 500 kbit/s. BOOT cycles scenarios:");
    ESP_LOGI(TAG, "  NORMAL → LUMBER RUN → FAULT → SLOW LEAK");

    uint32_t tick = 0;
    while (1) {
        uint32_t ms = (uint32_t)(esp_timer_get_time() / 1000);
        poll_button(ms);
        uint32_t elapsed = ms - scenario_started_ms;

        // The fault scenario sets the MIL ~5 s in, once there's context in
        // Merope's ring to capture.
        if (scenario == SCENARIO_FAULT && !mil_on && elapsed > 5000) {
            mil_on = true;
            dtc_count = 1;
            ESP_LOGW(TAG, "MIL set (scenario)");
        }

        float rpm, speed, coolant, throttle, load;
        drive_cycle(ms, &rpm, &speed, &coolant, &throttle, &load);

        send(mrp_frame_telem_a(rpm, speed, coolant, throttle, load));
        send(mrp_frame_telem_b(13.9f, 31.0f, 74.0f, 25.0f + throttle * 0.76f));
        send(mrp_frame_body(body_for_scenario(elapsed)));
        if (tick % STATUS_EVERY == 0) {
            send(mrp_frame_status(mil_on, dtc_count));
            float fl, fr, rl, rr;
            tpms_for_scenario(elapsed, &fl, &fr, &rl, &rr);
            send(mrp_frame_tpms(fl, fr, rl, rr));
        }
        if (tick % 20 == 0) {
            ESP_LOGI(TAG, "[%s] rpm %.0f  speed %.0f  coolant %.0f  mil %d",
                     scenario_name(scenario), rpm, speed, coolant, mil_on);
            report_bus();
        }

        tick++;
        vTaskDelay(pdMS_TO_TICKS(TX_PERIOD_MS));
    }
}

#endif  // MRP_APP_ELECTRA
