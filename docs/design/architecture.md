# pleiades — architecture

*Design doc, first artifact in the repo. Everything else answers to this.*

**Status:** living · **Started:** 2026-07-27 · **Vehicle:** 2022 Subaru Forester Wilderness (FB25D 2.5L NA boxer, CVT, Subaru Global Platform)

## What this is

A personal vehicle-telemetry platform: tap the Forester's OBD-II/CAN data, turn it
into one typed stream of readings, and render it however we want on an iPad —
gauges, logs, custom alert thresholds. Later, a hardwired CAN tap unlocks the
proprietary frames Subaru doesn't publish (including rear-gate latch state, which
is where the "drive with the gate open without the car screaming" project becomes
a platform feature instead of a screwdriver trick).

*Subaru* is the Japanese name for the Pleiades cluster — the logo is the six
stars. So the platform is **pleiades** and the components are the sisters.

## The star map

| Star | Component | Why |
|---|---|---|
| **pleiades** | The platform / this monorepo | The cluster itself |
| **Maia** | Core Swift library: protocol, PID catalog, decoding, transports | Eldest sister; mother of Hermes, the messenger god. The messenger layer. |
| **Alcyone** | The iPad app (SwiftUI gauges, layouts, logging) | Brightest star; Subaru's own precedent — the SVX was the *Alcyone* in Japan. The thing you look at. |
| **Merope** | CAN-tap hardware + ESP32 firmware | The "lost Pleiad," the star that hides. Buried behind trim panels. |
| **Sterope** | Alert/threshold engine (custom warnings; eventually the chime work) | *Sterope* = lightning in Greek. The one that warns you. |
| **Electra** | Bench/simulator: a fake car + fake ELM327 | The electrical bench. |
| Taygeta, Celaeno, Atlas, Pleione | Reserved | Future load-bearing pieces (Celaeno — the dark one — is earmarked for the log archive). |

## Architecture

One data pipeline; everything else is a view on it.

```
Forester CAN bus
   └─ adapter ─────────── phase 1: BLE ELM327 dongle (standard PIDs)
        │                  phase 3: Merope — custom ESP32 tap (proprietary frames)
   Maia ──────────────── transport-agnostic core → typed reading stream
        ├─ Alcyone ────── gauges, layouts, log views (iPad)
        ├─ Sterope ────── thresholds → alerts
        └─ Electra ────── fake car, so everything above builds on the couch
```

Two load-bearing rules:

1. **Transports are swappable.** BLE dongle, WiFi dongle, ESP32 bridge, and the
   Electra emulator all implement one small `OBDTransport` protocol
   (`send(command) async throws -> String` for the ELM dialect; a frame-level
   equivalent arrives with Merope). Nothing above the transport knows which one
   is plugged in.
2. **Protocol frontends converge.** ELM327 PID polling and raw CAN frame
   decoding are different dialects that emit the *same* typed reading stream.
   Alcyone never knows where a number came from.

### Maia internals (phase 0 scope)

- `PID` — one parameter: mode, code, unit, payload width, decode closure.
  Ships a curated standard mode-01 catalog (see appendix A).
- `ELM327Session` — actor speaking the AT/PID dialect over any transport:
  init handshake (`ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH0`, `ATSP0`), single-PID
  reads, supported-PID bitmask walk (`0100`/`0120`/…), MIL status (mode 01
  PID 01), stored-DTC read (mode 03, `DTC` ↔ "P0420" both directions), and
  code clearing (mode 04 — user-initiated only, never polled).
- `ELMTCPTransport` — WiFi dongles (raw TCP, conventionally 192.168.0.10:35000).
  Also what the CLI bench tool uses.
- BLE transport lands with Alcyone (CoreBluetooth wants an app context).

### Electra internals (phase 0 scope)

- `ElectraCar` — actor with a plausible-physics vehicle model: throttle drives
  RPM/speed, coolant warms toward 90 °C, voltage tracks engine state. Time is
  injected (`advance(by:)`), so tests are deterministic and the demo can run
  real-time.
- `ELM327Emulator` — wraps an `ElectraCar` in the ELM dialect and implements
  `OBDTransport`. Answers AT commands, supported-PID pages, and mode-01
  requests by encoding the car's current state. The same `ELM327Session` that
  will talk to the real dongle talks to Electra unmodified — that's the point.

## Phases

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **0 — Electra first** | Maia core + Electra fake car + CLI `demo` | `swift test` green; `pleiades demo` streams a warmup cycle with zero hardware |
| **1 — First contact** | BLE dongle on the real Forester | Supported-PID map of the actual FB25D captured into the repo; one logged real drive |
| **2 — Alcyone** | iPad app: CoreBluetooth transport, gauge dashboard, layouts, logging | Live gauges on the dash of the actual car |
| **3 — Merope** | ESP32 + CAN transceiver tap; proprietary frame decoding (opendbc Subaru DBC as a head start) | Rear-gate latch state readable; first non-OBD signal on an Alcyone gauge |
| **4 — Sterope grows up** | Custom thresholds/alerts; gate-open chime handling designed on top of real latch data | TBD after phase 3 findings. *Started early:* the rules engine (hysteresis triggers over the reading stream) + Alcyone alert banners already run on the bench; Electra injects faults to rehearse the check-engine flow. Chime work still gated on Merope. |

## Snapshot & history architecture

Three layers, each with its own memory and its own trigger:

1. **The ECU's freeze frame (exists today, phases 0–2).** The car itself
   captures a one-instant sensor snapshot when a code sets — we don't trigger
   it, we *read* it (mode 02). Alcyone polls DTCs at 1 Hz; when a new code
   appears it pulls the ECU's frame and archives it. This works even for
   faults that happened while the app wasn't connected: the frame sits in the
   ECU until read or cleared, and Celaeno's dedup records it exactly once on
   next connect.
2. **Celaeno on the iPad (exists today).** The archive of record — append-only
   JSON in Application Support. Survives code clearing by design: the ECU
   forgets, Celaeno doesn't.
3. **Merope as black box (phase 3 decision).** Once an always-powered ESP32
   sits on the bus, snapshot capture *should* move down to it: a rolling ring
   buffer of recent telemetry in RAM, flushed to flash (LittleFS, modest write
   budget) when a fault trips. That upgrades the snapshot from the ECU's
   single instant to **N seconds before and after the event**, and it works
   with the iPad at home on the charger. Trigger: watch MIL/DTC-count state
   (poll PID 01, or the proprietary CAN frame carrying MIL once decoded) and
   fire on change. Merope then syncs staged events up to Celaeno when Alcyone
   next connects — Celaeno stays the archive of record; Merope is a staging
   buffer, not a second source of truth.

## Hardware notes

**Phase 1 dongle — the iOS constraint:** iPads/iPhones cannot talk to cheap
Bluetooth-Classic ELM327s at all. Options:

- **Vgate iCar Pro BLE 4.0** (~$35) — the community-standard BLE choice. *Default pick.*
- **OBDLink CX** (~$100) — nicer firmware, faster polling, also BLE.
- WiFi dongles work but hijack the iPad's WiFi connection while attached.

**Phase 3 tap:** ESP32 (built-in TWAI/CAN controller) + a 3.3 V transceiver
(SN65HVD230 class). Tap point TBD: OBD-port Y-splitter first (reversible,
no trim removal), behind-trim vampire tap only once Merope earns permanence.
opendbc's Subaru Global Platform DBCs cover the 2022 Forester — verify signal
names against sniffed traffic before trusting any of them.

## Known truths & constraints (from prior research)

- **Oil pressure is not on the bus.** The FB25 has a low-pressure switch, not a
  sender — no amount of tapping conjures a number. Getting one means adding an
  aftermarket sender (Sterope-era decision).
- Standard-PID coverage **confirmed 2026-07-30** against the real FB25D: 57
  standard PIDs answered. Oil temp (`5C`) is supported; fuel rate (`5E`) is
  not. See appendix A.
- The gate-ajar chime exists because exhaust can pull into the cabin through an
  open gate. Whatever Sterope eventually does about the chime, the CO caution
  stays in the docs. Windows cracked.
- Merope transmits when we want it to. Listen-only is a *mode* we use during
  recon (hearing without participating), not a policy. Practical caution
  only: frames asserting state are read by modules we haven't decoded, so
  effects can appear far from where they were aimed — which is what the
  full-bus recording is for.

## Open questions

- [ ] Does the 2022 FB25D answer `5C` (oil temp) and `5E` (fuel rate)? (Phase 1.)
- [ ] Which CAN segment carries the gate-latch state on the 2022 Forester, and is
  it visible from the OBD port or only behind the gateway? (Phase 3 recon.)
- [ ] Dongle: Vgate iCar Pro vs OBDLink CX — buy cheap first or nice once?
- [ ] Alcyone v1 scope: gauges only, or logging + Sterope thresholds from day one?
- [ ] Mounting: where does the iPad live in the cabin?

## Appendix A — standard PID set (mode 01)

**Verified 2026-07-30** against the actual 2022 Forester Wilderness (FB25D)
with a Vgate iCar Pro over BLE. The ECU answers **57** standard PIDs; 20 are
in Maia's catalog. Formulas are the SAE J1979 standards.

Findings that closed open questions:

- **`5C` oil temp — supported.** Good news; it was a coin flip.
- **`5E` fuel rate — not supported.** Drop it from the default polling set.
- 37 supported PIDs are outside Maia's catalog and worth mining, notably
  `03` (fuel system status), `1C` (OBD standard), `2C`–`2E` (EGR/EVAP),
  `30` (warm-ups since cleared), `34` (O2 sensor wide-range), `4C`–`4E`
  (commanded throttle, run time with MIL, time since cleared), `5A`
  (relative accelerator position), and the `80`+ range (manufacturer
  extended data).
- Adapter reports **ELM327 v2.3**, protocol 6 (ISO 15765-4, CAN 11-bit,
  500 kbit/s). Forcing protocol 6 avoids a slow auto-search — worth doing in
  the app's transport too.

### Live sample at idle (engine warm)

```
Engine load        36.5 %      Timing advance      2.5 °BTDC
Short fuel trim   -0.8 %       Intake air temp    52.0 °C
Long fuel trim    -3.9 %       Manifold pressure  37.0 kPa
RPM              903.0 rpm     Speed               0.0 km/h
```

Fuel trims within a few percent of zero — a healthy engine, and a useful
baseline for SHED-85's fingerprinting.

| PID | Name | Formula | Unit | Notes |
|---|---|---|---|---|
| 04 | Engine load | A/2.55 | % | |
| 05 | Coolant temp | A−40 | °C | |
| 06 | Short fuel trim B1 | A/1.28−100 | % | |
| 07 | Long fuel trim B1 | A/1.28−100 | % | engine-health tell |
| 0B | Manifold pressure | A | kPa | NA boxer: vacuum proxy |
| 0C | RPM | (256A+B)/4 | rpm | |
| 0D | Speed | A | km/h | |
| 0E | Timing advance | A/2−64 | °BTDC | |
| 0F | Intake air temp | A−40 | °C | |
| 10 | MAF | (256A+B)/100 | g/s | |
| 11 | Throttle | A/2.55 | % | |
| 2F | Fuel level | A/2.55 | % | |
| 33 | Barometric pressure | A | kPa | trailhead altitude, effectively |
| 3C | Catalyst temp B1S1 | (256A+B)/10−40 | °C | |
| 42 | Battery voltage | (256A+B)/1000 | V | |
| 46 | Ambient air temp | A−40 | °C | |
| 5C | Oil temp | A−40 | °C | **spotty** — verify phase 1 |
| 5E | Fuel rate | (256A+B)/20 | L/h | **spotty** — verify phase 1 |
