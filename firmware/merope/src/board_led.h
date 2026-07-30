// The DevKitC-1's single WS2812, driven straight off RMT.
//
// Two identical boards on a desk are impossible to tell apart, so each
// firmware claims a color: Electra amber, Merope violet — matching their
// Linear labels. Status is encoded in brightness/hue changes from there.
//
// Deliberately dependency-free: the espressif/led_strip managed component
// doesn't build against ESP-IDF 6 (its SPI backend misses a heap header),
// and a WS2812 is only two pulse widths.
#pragma once

#include <stdint.h>

#include "driver/rmt_tx.h"
#include "esp_err.h"

#ifndef MRP_LED_GPIO
#define MRP_LED_GPIO 48
#endif

static rmt_channel_handle_t s_led_chan;
static rmt_encoder_handle_t s_led_encoder;

static inline void board_led_init(void) {
    rmt_tx_channel_config_t chan = {
        .gpio_num = MRP_LED_GPIO,
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000,  // 0.1 µs per tick
        .mem_block_symbols = 64,
        .trans_queue_depth = 4,
    };
    if (rmt_new_tx_channel(&chan, &s_led_chan) != ESP_OK) {
        s_led_chan = NULL;
        return;
    }

    // WS2812: a bit is one high pulse then one low pulse; which is longer
    // encodes 0 or 1.
    rmt_bytes_encoder_config_t bytes = {
        .bit0 = {.level0 = 1, .duration0 = 3, .level1 = 0, .duration1 = 9},
        .bit1 = {.level0 = 1, .duration0 = 9, .level1 = 0, .duration1 = 3},
        .flags = {.msb_first = 1},
    };
    if (rmt_new_bytes_encoder(&bytes, &s_led_encoder) != ESP_OK) {
        s_led_chan = NULL;
        return;
    }
    rmt_enable(s_led_chan);
}

static inline void board_led_set(uint8_t r, uint8_t g, uint8_t b) {
    if (!s_led_chan) return;
    uint8_t grb[3] = {g, r, b};  // WS2812 wants green first
    rmt_transmit_config_t tx = {.loop_count = 0};
    rmt_transmit(s_led_chan, s_led_encoder, grb, sizeof(grb), &tx);
}
