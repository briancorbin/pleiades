#include "merope_ring.h"

void mrp_ring_init(mrp_ring_t *r, mrp_sample_t *storage, size_t capacity) {
    r->buf = storage;
    r->capacity = capacity;
    r->head = 0;
    r->count = 0;
}

void mrp_ring_push(mrp_ring_t *r, mrp_sample_t sample) {
    r->buf[r->head] = sample;
    r->head = (r->head + 1) % r->capacity;
    if (r->count < r->capacity) {
        r->count++;
    }
}

size_t mrp_ring_count(const mrp_ring_t *r) {
    return r->count;
}

size_t mrp_ring_window(const mrp_ring_t *r, uint32_t since_ms,
                       mrp_sample_t *out, size_t out_max) {
    size_t copied = 0;
    size_t oldest = (r->head + r->capacity - r->count) % r->capacity;
    for (size_t i = 0; i < r->count && copied < out_max; i++) {
        const mrp_sample_t *s = &r->buf[(oldest + i) % r->capacity];
        if (s->ms >= since_ms) {
            out[copied++] = *s;
        }
    }
    return copied;
}
