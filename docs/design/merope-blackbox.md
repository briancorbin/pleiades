# Merope — the black box

*Design for the phase-3 CAN tap's headline feature: a rolling telemetry
buffer that turns "a code set" into "here's the 90 seconds around it."*

**Status:** design · **Depends on:** nothing until parts arrive; buffer logic is host-testable day one

## The idea

The ECU's freeze frame is one mandated instant. Merope — always powered,
always on the bus — keeps a **rolling ring buffer of decoded telemetry in
RAM**, and when a fault trips it freezes the pre-window, keeps recording a
post-window, and writes the whole event to flash. Alcyone syncs staged events
into Celaeno on next connect. ECU contributes its instant; Merope contributes
the movie.

## Bill of materials (~$30–45)

| Part | Pick | ~Cost | Why |
|---|---|---|---|
| MCU | **ESP32-S3 DevKitC, 8 MB PSRAM variant** | $10–15 | Built-in TWAI (CAN 2.0) controller; PSRAM is the ring buffer — 8 MB ≈ tens of minutes of decoded telemetry. Dual core: one for CAN RX, one for everything else. |
| CAN transceiver | **SN65HVD230 breakout** | $3 | 3.3 V logic — matches the ESP32 directly. (Avoid TJA1050 boards; they're 5 V.) |
| Bus access | **OBD-II Y-splitter cable** | $8–12 | Pins 6/14 = CAN-H/L, 16 = battery 12 V, 4/5 = ground. The Y keeps the port free for the dongle or an inspection scanner. |
| Power | **12 V→5 V buck module** + inline 1–2 A fuse | $3–5 | Pin 16 is always-hot battery power; automotive 12 V is nasty (13.8 V running, transient spikes), so a decent buck, not a bare regulator. |
| Storage | On-chip flash (LittleFS partition) | $0 | Staged fault events are small; keep last ~20. microSD only if we later want continuous logging. |

## Firmware architecture

PlatformIO project at `firmware/merope/` (builds headless with `pio run`;
ring-buffer and trigger logic unit-test on the host in the `native` env — the
Electra philosophy, in C).

FreeRTOS tasks:

1. **CAN RX** — TWAI driver in listen-only mode *during recon*: no ACK bit,
   electrically unable to disturb the bus while we're still learning what's
   on it. Not a permanent restriction — see SHED-93/94 for the transmit
   path that makes Merope the single gateway. Hardware filters → decode signals of interest via a table
   derived from the opendbc Subaru DBC → push `(ms, signalId, value)` into
   the ring.
2. **Ring buffer** — fixed circular array in PSRAM. Budget math: ~8 bytes per
   decoded update × a few hundred updates/sec ≈ 2 KB/s → 8 MB holds ~an hour;
   we only *need* 60 s pre + 30 s post per event.
3. **Fault watcher** — passive-first because it's cheaper, not because TX is
   forbidden: once the proprietary frame carrying MIL/DTC-count state is
   decoded, watch it for edges. Fallback is polling PID 0101 once a second
   (SHED-94's request scheduler).
4. **Event writer** — on trigger: snapshot the pre-window, record the
   post-window, finalize one bounded event file to LittleFS.
5. **Sync + transport** — BLE GATT service ("Merope"): list events, download
   event, and a live decoded-signal stream. That last characteristic doubles
   as a `MeropeSource: TelemetrySource` for Alcyone later — same protocol
   convergence rule as everything else.
6. **Power manager** — bus silent (car off) → deep sleep; wake on CAN RX
   edge via GPIO interrupt. Parked-drain target well under 1 mA so pin 16
   never murders the battery.

Clock: no RTC battery on the ESP32 — events are stamped in
milliseconds-since-boot and converted to wall-clock at sync time (the iPad
supplies the offset; Celaeno stores corrected dates).

## Build order

1. **Host-testable core (no hardware):** ring buffer + trigger/window logic
   as plain C with unit tests under PlatformIO `native`. ✅ *Done 2026-07-27 —
   `firmware/merope/lib/merope_core`, 11 tests via `pio test -e native`.*
2. **Desk bench:** second ESP32 flashed as *Electra-on-a-wire* — replays
   plausible Forester CAN traffic so the black box develops entirely on the
   desk, mirroring how Alcyone developed against Electra.
3. **Car recon:** listen-only on the real bus via the Y-splitter — hearing
   without participating while we're still learning what's there. Log raw
   frames, diff against opendbc, find the MIL frame and the gate-latch frame.
4. **Live black box:** trigger on real MIL edges; BLE sync into Celaeno.

## Open questions

- [ ] Which CAN segment is visible at the OBD port on the 2022 Forester, and
  is the gate-latch state on it — or only behind the body gateway?
- [ ] PSRAM ring granularity: decoded signals only, or also a smaller raw
  frame ring for later re-decoding?
- [ ] Sterope-on-Merope: should threshold rules eventually run on the ESP32
  too (alerts with the iPad absent), or stay iPad-only?
