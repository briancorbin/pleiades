// Host-build placeholder. The real firmware entry points are
// merope_main.c and electra_main.c, selected by MRP_APP_* build flags —
// see platformio.ini. Everything interesting lives in lib/merope_core.
#ifndef ESP_PLATFORM
int main(void) {
    return 0;
}
#endif
