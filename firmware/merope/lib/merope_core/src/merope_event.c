#include "merope_event.h"

#include <string.h>

static const uint8_t MAGIC[4] = {'M', 'R', 'P', 'E'};

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

size_t mrp_event_encoded_size(uint16_t sample_count) {
    return MRP_EVENT_HEADER_SIZE + (size_t)sample_count * MRP_EVENT_SAMPLE_SIZE;
}

size_t mrp_event_encode(const mrp_event_t *event, uint8_t *out, size_t out_max) {
    size_t needed = mrp_event_encoded_size(event->sample_count);
    if (out_max < needed) {
        return 0;
    }
    memcpy(out, MAGIC, 4);
    out[4] = MRP_EVENT_VERSION;
    put_u32(out + 5, event->trigger_ms);
    out[9] = event->mil_on ? 1 : 0;
    out[10] = event->dtc_count;
    put_u16(out + 11, event->sample_count);

    uint8_t *p = out + MRP_EVENT_HEADER_SIZE;
    for (uint16_t i = 0; i < event->sample_count; i++) {
        const mrp_sample_t *s = &event->samples[i];
        put_u32(p, s->ms);
        put_u16(p + 4, s->signal);
        uint32_t bits;
        memcpy(&bits, &s->value, 4);
        put_u32(p + 6, bits);
        p += MRP_EVENT_SAMPLE_SIZE;
    }
    return needed;
}

bool mrp_event_decode(const uint8_t *buf, size_t len, mrp_event_t *event,
                      mrp_sample_t *samples_out, uint16_t samples_max) {
    if (len < MRP_EVENT_HEADER_SIZE || memcmp(buf, MAGIC, 4) != 0 ||
        buf[4] != MRP_EVENT_VERSION) {
        return false;
    }
    uint16_t count = get_u16(buf + 11);
    if (count > samples_max || len < mrp_event_encoded_size(count)) {
        return false;
    }
    event->trigger_ms = get_u32(buf + 5);
    event->mil_on = buf[9] != 0;
    event->dtc_count = buf[10];
    event->sample_count = count;
    event->samples = samples_out;

    const uint8_t *p = buf + MRP_EVENT_HEADER_SIZE;
    for (uint16_t i = 0; i < count; i++) {
        samples_out[i].ms = get_u32(p);
        samples_out[i].signal = get_u16(p + 4);
        uint32_t bits = get_u32(p + 6);
        memcpy(&samples_out[i].value, &bits, 4);
        p += MRP_EVENT_SAMPLE_SIZE;
    }
    return true;
}
