// Fault watcher: turns a stream of MIL/DTC-count observations into capture
// events with a pre/post window. Passive by design — it only *observes*;
// where the observations come from (proprietary CAN frame or PID 0101 poll)
// is the caller's problem.
#ifndef MEROPE_WATCH_H
#define MEROPE_WATCH_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t pre_ms;   // how much history to keep before the trigger
    uint32_t post_ms;  // how long to keep recording after it

    // internal state
    bool baseline_set;
    bool prev_mil;
    uint8_t prev_count;
    bool capturing;
    uint32_t trigger_ms;
} mrp_watch_t;

void mrp_watch_init(mrp_watch_t *w, uint32_t pre_ms, uint32_t post_ms);

// Feed one MIL observation. Returns true exactly when a NEW fault fires
// (MIL rising edge, or the stored-code count increasing). The first
// observation only sets the baseline — a car that boots with the MIL
// already on is old news, not an event. While a capture is in progress,
// further faults do not re-fire.
bool mrp_watch_feed(mrp_watch_t *w, uint32_t now_ms, bool mil_on,
                    uint8_t dtc_count);

// True once the post-window has elapsed after a trigger; resets the watcher
// to idle so the caller can finalize the event exactly once.
bool mrp_watch_capture_due(mrp_watch_t *w, uint32_t now_ms);

// While capturing: the ms value the event window starts at (trigger - pre),
// clamped at 0. Meaningless when not capturing.
uint32_t mrp_watch_window_start(const mrp_watch_t *w);

#ifdef __cplusplus
}
#endif

#endif  // MEROPE_WATCH_H
