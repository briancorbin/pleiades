#include "merope_watch.h"

void mrp_watch_init(mrp_watch_t *w, uint32_t pre_ms, uint32_t post_ms) {
    w->pre_ms = pre_ms;
    w->post_ms = post_ms;
    w->baseline_set = false;
    w->prev_mil = false;
    w->prev_count = 0;
    w->capturing = false;
    w->trigger_ms = 0;
}

bool mrp_watch_feed(mrp_watch_t *w, uint32_t now_ms, bool mil_on,
                    uint8_t dtc_count) {
    if (!w->baseline_set) {
        w->baseline_set = true;
        w->prev_mil = mil_on;
        w->prev_count = dtc_count;
        return false;
    }

    bool fired = (mil_on && !w->prev_mil) || (dtc_count > w->prev_count);
    w->prev_mil = mil_on;
    w->prev_count = dtc_count;

    if (fired && !w->capturing) {
        w->capturing = true;
        w->trigger_ms = now_ms;
        return true;
    }
    return false;
}

bool mrp_watch_capture_due(mrp_watch_t *w, uint32_t now_ms) {
    if (!w->capturing) {
        return false;
    }
    if (now_ms - w->trigger_ms >= w->post_ms) {
        w->capturing = false;
        return true;
    }
    return false;
}

uint32_t mrp_watch_window_start(const mrp_watch_t *w) {
    return w->trigger_ms > w->pre_ms ? w->trigger_ms - w->pre_ms : 0;
}
