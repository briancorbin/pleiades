// Merope's BLE face: it impersonates an ELM327 adapter.
//
// Alcyone already speaks ELM327 over a GATT serial port (BLEELMTransport,
// built for the dongle). Rather than invent a Merope-specific protocol and
// a matching client, Merope advertises the same FFF0 service and answers
// the same AT/PID commands — from decoded CAN signals instead of from an
// OBD request. The app connects with zero changes.
//
// This is the architecture's "protocol frontends converge" rule: whatever
// the source, it ends up as the same typed reading stream upstream.
#pragma once

#include <stdbool.h>
#include <stdint.h>

/// Start advertising. Device name contains "OBD" so the app's adapter
/// filter picks it up.
void mrp_ble_init(void);

/// Publish the latest value for a signal (signal ids are OBD PID codes).
void mrp_ble_update_signal(uint16_t signal, float value);

/// Publish MIL state so mode 01 PID 01 and mode 03 answer truthfully.
void mrp_ble_update_status(bool mil_on, uint8_t dtc_count);

/// True once a central has subscribed.
bool mrp_ble_connected(void);

/// Human-readable BLE state for the periodic status line.
const char *mrp_ble_state(void);
