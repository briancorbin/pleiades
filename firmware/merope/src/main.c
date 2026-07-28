// Merope firmware entry. The real FreeRTOS tasks (CAN RX, event writer,
// BLE sync, power manager) land when hardware arrives — see
// docs/design/merope-blackbox.md. Everything interesting today lives in
// lib/merope_core and is host-tested via `pio test -e native`.
#ifdef ESP_PLATFORM
void app_main(void) {}
#else
int main(void) {
    return 0;
}
#endif
