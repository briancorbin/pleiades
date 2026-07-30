// Hardware self-test for one board + its transceiver. No CAN protocol, no
// second board, no bus wires — just DC levels.
//
// An SN65HVD230 loops back: drive D (CTX) low and the bus goes dominant, so
// R (CRX) reads low; let D go high and the bus idles recessive, so R reads
// high. If power and both signal wires are good, RX *must* mirror TX.
//
// The internal pull is deliberately set against the level we expect, so a
// disconnected pin is distinguishable from a driven one: a floating pin
// follows the pull, a driven pin overrides it.
#ifdef MRP_APP_SELFTEST

#include <stdio.h>

#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "board_led.h"

static const char *TAG = "selftest";

#define TX_PIN MRP_TWAI_TX
#define RX_PIN MRP_TWAI_RX

/// Read RX with the internal pull fighting the expected level, so we can
/// tell "driven" from "floating".
static int read_rx_against(gpio_pull_mode_t pull) {
    gpio_set_pull_mode(RX_PIN, pull);
    vTaskDelay(pdMS_TO_TICKS(20));
    return gpio_get_level(RX_PIN);
}

void app_main(void) {
    board_led_init();
    board_led_set(30, 30, 0);  // yellow: testing

    gpio_config_t tx = {
        .pin_bit_mask = 1ULL << TX_PIN,
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&tx);

    gpio_config_t rx = {
        .pin_bit_mask = 1ULL << RX_PIN,
        .mode = GPIO_MODE_INPUT,
    };
    gpio_config(&rx);

    vTaskDelay(pdMS_TO_TICKS(500));
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "=== transceiver loopback self-test ===");
    ESP_LOGI(TAG, "TX = GPIO%d → CTX,  RX = GPIO%d ← CRX", TX_PIN, RX_PIN);
    ESP_LOGI(TAG, "");

    while (1) {
        // Recessive: TX high. RX should read HIGH even with a pulldown
        // fighting it, because the transceiver is actively driving it.
        gpio_set_level(TX_PIN, 1);
        int recessive = read_rx_against(GPIO_PULLDOWN_ONLY);

        // Dominant: TX low. RX should read LOW even against a pullup.
        gpio_set_level(TX_PIN, 0);
        int dominant = read_rx_against(GPIO_PULLUP_ONLY);

        // Is anything driving RX at all? A floating pin just follows
        // whichever internal pull is applied.
        gpio_set_level(TX_PIN, 1);
        int floats_low = read_rx_against(GPIO_PULLDOWN_ONLY);
        int floats_high = read_rx_against(GPIO_PULLUP_ONLY);
        bool rx_floating = (floats_low == 0 && floats_high == 1);

        ESP_LOGI(TAG, "TX=1 → RX reads %d   (want 1)", recessive);
        ESP_LOGI(TAG, "TX=0 → RX reads %d   (want 0)", dominant);

        if (recessive == 1 && dominant == 0) {
            ESP_LOGI(TAG, "");
            ESP_LOGI(TAG, "  ✅ PASS — power, CTX and CRX are all good on this board.");
            ESP_LOGI(TAG, "     The transceiver is looping back correctly.");
            board_led_set(0, 40, 0);  // green
        } else if (rx_floating) {
            ESP_LOGE(TAG, "");
            ESP_LOGE(TAG, "  ❌ RX pin is FLOATING — nothing is driving GPIO%d.", RX_PIN);
            ESP_LOGE(TAG, "     Nothing reaches the chip. In order of likelihood:");
            ESP_LOGE(TAG, "       1. transceiver has no power  → measure 3.3V↔GND on it");
            ESP_LOGE(TAG, "       2. CRX→GPIO%d wire not seated / wrong pin", RX_PIN);
            ESP_LOGE(TAG, "       3. dead transceiver");
            board_led_set(40, 0, 0);  // red
        } else if (recessive == 0 && dominant == 0) {
            ESP_LOGE(TAG, "");
            ESP_LOGE(TAG, "  ❌ RX stuck LOW (bus permanently dominant).");
            ESP_LOGE(TAG, "     Usually CTX shorted low, or CANH/CANL shorted together.");
            board_led_set(40, 0, 0);
        } else if (recessive == 1 && dominant == 1) {
            ESP_LOGE(TAG, "");
            ESP_LOGE(TAG, "  ❌ RX stuck HIGH — RX sees idle no matter what TX does.");
            ESP_LOGE(TAG, "     The CTX→GPIO%d wire probably isn't connected, so the", TX_PIN);
            ESP_LOGE(TAG, "     transceiver never gets told to drive the bus.");
            board_led_set(40, 0, 0);
        } else {
            ESP_LOGE(TAG, "  ❌ RX is INVERTED — CTX and CRX are likely swapped.");
            board_led_set(40, 0, 0);
        }
        ESP_LOGI(TAG, "");
        vTaskDelay(pdMS_TO_TICKS(3000));
    }
}

#endif  // MRP_APP_SELFTEST
