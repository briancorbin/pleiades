#ifdef MRP_APP_MEROPE

#include "merope_ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "merope-ble";

// The FFF0 "serial port" layout Alcyone's BLEELMTransport looks for first:
// commands written to FFF2, responses notified on FFF1.
static const ble_uuid16_t SVC_UUID = BLE_UUID16_INIT(0xFFF0);
static const ble_uuid16_t CHR_NOTIFY_UUID = BLE_UUID16_INIT(0xFFF1);
static const ble_uuid16_t CHR_WRITE_UUID = BLE_UUID16_INIT(0xFFF2);

#define MAX_SIGNAL 0x60
static float s_values[MAX_SIGNAL];
static bool s_have[MAX_SIGNAL];
static bool s_mil;
static uint8_t s_dtc_count;

static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_notify_handle;
static bool s_subscribed;
static bool s_advertising;

static void advertise(void);

void mrp_ble_update_signal(uint16_t signal, float value) {
    if (signal < MAX_SIGNAL) {
        s_values[signal] = value;
        s_have[signal] = true;
    }
}

void mrp_ble_update_status(bool mil_on, uint8_t dtc_count) {
    s_mil = mil_on;
    s_dtc_count = dtc_count;
}

bool mrp_ble_connected(void) {
    return s_subscribed;
}

const char *mrp_ble_state(void) {
    if (s_subscribed) return "connected (Alcyone listening)";
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) return "connected, not subscribed";
    if (s_advertising) return "advertising as MEROPE-OBD";
    return "not advertising";
}

/// Send a response, split to fit the negotiated MTU. The app reassembles by
/// accumulating until the '>' prompt, so chunk boundaries don't matter.
static void respond(const char *text) {
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    size_t len = strlen(text);
    size_t sent = 0;
    while (sent < len) {
        size_t chunk = len - sent > 20 ? 20 : len - sent;
        struct os_mbuf *om = ble_hs_mbuf_from_flat(text + sent, chunk);
        if (!om) return;
        if (ble_gatts_notify_custom(s_conn_handle, s_notify_handle, om) != 0) return;
        sent += chunk;
    }
}

/// Build a mode-01 reply for one PID from the latest decoded signal, using
/// the same encodings the real ECU would. Returns false when we have no
/// value for it, which becomes NO DATA — exactly like a car that doesn't
/// support a PID.
static bool encode_pid(uint8_t pid, char *out, size_t out_len) {
    if (pid >= MAX_SIGNAL || !s_have[pid]) return false;
    float v = s_values[pid];

    switch (pid) {
    case 0x04:  // engine load %
    case 0x11:  // throttle %
    case 0x2F:  // fuel level %
        snprintf(out, out_len, "41%02X%02X\r\r>", pid, (uint8_t)(v * 2.55f));
        return true;
    case 0x05:  // coolant temp
    case 0x0F:  // intake temp
        snprintf(out, out_len, "41%02X%02X\r\r>", pid, (uint8_t)(v + 40.0f));
        return true;
    case 0x0B:  // manifold pressure kPa
        snprintf(out, out_len, "41%02X%02X\r\r>", pid, (uint8_t)v);
        return true;
    case 0x0C: {  // rpm, quarter-rpm resolution
        uint16_t q = (uint16_t)(v * 4.0f);
        snprintf(out, out_len, "410C%02X%02X\r\r>", q >> 8, q & 0xFF);
        return true;
    }
    case 0x0D:  // speed km/h
        snprintf(out, out_len, "410D%02X\r\r>", (uint8_t)v);
        return true;
    case 0x42: {  // control module voltage, millivolts
        uint16_t mv = (uint16_t)(v * 1000.0f);
        snprintf(out, out_len, "4142%02X%02X\r\r>", mv >> 8, mv & 0xFF);
        return true;
    }
    default:
        return false;
    }
}

/// The supported-PID bitmask for page 0 (PIDs 01–20), built from whatever
/// we've actually decoded off the bus.
static void encode_supported(char *out, size_t out_len) {
    uint8_t mask[4] = {0, 0, 0, 0};
    for (uint8_t pid = 1; pid <= 0x20; pid++) {
        bool supported = (pid == 0x01) || (pid < MAX_SIGNAL && s_have[pid]);
        if (supported) {
            uint8_t index = pid - 1;
            mask[index / 8] |= 0x80 >> (index % 8);
        }
    }
    snprintf(out, out_len, "4100%02X%02X%02X%02X\r\r>", mask[0], mask[1], mask[2], mask[3]);
}

static void handle_command(const char *raw, size_t len) {
    char cmd[32] = {0};
    size_t n = 0;
    for (size_t i = 0; i < len && n < sizeof(cmd) - 1; i++) {
        char c = raw[i];
        if (c == '\r' || c == '\n' || c == ' ') continue;
        cmd[n++] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
    }
    if (n == 0) return;

    char out[64];

    if (strncmp(cmd, "AT", 2) == 0) {
        if (strcmp(cmd, "ATZ") == 0 || strcmp(cmd, "ATI") == 0) {
            respond("ELM327 v1.5 (Merope)\r\r>");
        } else {
            respond("OK\r\r>");
        }
        return;
    }

    // Mode 03 — stored codes. Merope knows MIL state from the bus, but the
    // codes themselves need a real OBD request, so report the count with a
    // placeholder code until UDS querying exists.
    if (strcmp(cmd, "03") == 0) {
        if (s_mil && s_dtc_count > 0) {
            respond("4301FFFF\r\r>");
        } else {
            respond("4300\r\r>");
        }
        return;
    }
    if (strcmp(cmd, "04") == 0) {
        respond("44\r\r>");  // Merope is read-only; acknowledge, change nothing
        return;
    }

    if (n == 4 && cmd[0] == '0' && cmd[1] == '1') {
        unsigned pid = 0;
        if (sscanf(cmd + 2, "%2x", &pid) != 1) {
            respond("?\r\r>");
            return;
        }
        if (pid == 0x00) {
            encode_supported(out, sizeof(out));
            respond(out);
            return;
        }
        if (pid == 0x01) {  // MIL status
            uint8_t a = (uint8_t)((s_mil ? 0x80 : 0) | (s_dtc_count & 0x7F));
            snprintf(out, sizeof(out), "4101%02X000000\r\r>", a);
            respond(out);
            return;
        }
        if (encode_pid((uint8_t)pid, out, sizeof(out))) {
            respond(out);
        } else {
            respond("NO DATA\r\r>");
        }
        return;
    }

    respond("NO DATA\r\r>");
}

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        char buf[64];
        uint16_t len = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &len) == 0) {
            buf[len] = '\0';
            handle_command(buf, len);
        }
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def gatt_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &SVC_UUID.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &CHR_NOTIFY_UUID.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ,
                .val_handle = &s_notify_handle,
            },
            {
                .uuid = &CHR_WRITE_UUID.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {0},
        },
    },
    {0},
};

static int gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            ESP_LOGI(TAG, "central connected");
        } else {
            advertise();
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "central disconnected");
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed = false;
        advertise();
        return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        s_subscribed = event->subscribe.cur_notify;
        ESP_LOGI(TAG, "notifications %s", s_subscribed ? "on — Alcyone is listening" : "off");
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        return 0;
    default:
        return 0;
    }
}

static void advertise(void) {
    struct ble_hs_adv_fields fields = {0};
    const char *name = ble_svc_gap_device_name();
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)name;
    fields.name_len = strlen(name);
    fields.name_is_complete = 1;
    fields.uuids16 = (ble_uuid16_t[]){SVC_UUID};
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    ble_gap_adv_set_fields(&fields);

    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    int rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    s_advertising = (rc == 0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_adv_start failed: %d", rc);
    }
}

static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    advertise();
    ESP_LOGI(TAG, "advertising as \"MEROPE-OBD\" (ELM327 emulation on FFF0)");
}

static void host_task(void *param) {
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void mrp_ble_init(void) {
    if (nimble_port_init() != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed");
        return;
    }
    ble_hs_cfg.sync_cb = on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_gatts_count_cfg(gatt_services);
    ble_gatts_add_svcs(gatt_services);
    // "OBD" in the name so Alcyone's adapter filter matches it.
    ble_svc_gap_device_name_set("MEROPE-OBD");

    nimble_port_freertos_init(host_task);
}

#endif  // MRP_APP_MEROPE
