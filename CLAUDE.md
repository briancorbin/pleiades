# pleiades

Vehicle telemetry and chime control for a **2022 Subaru Forester Wilderness**
(FB25D). Public OSS, MIT. Started because the rear-gate chime can't be
silenced from any menu, and escalated into tapping the whole car.

*Subaru* is Japanese for the Pleiades, so the components are the sisters.

## Read these first

| File | What it settles |
|---|---|
| `docs/SIGNALS.md` | **Every module and identifier we know, and how we know it.** Generated — never edit by hand. |
| `docs/design/can-access.md` | The car's network topology and where to tap. |
| `docs/design/did-discovery.md` | How identifiers get found. The method, and what it cost to learn. |
| `docs/design/chimes.md` | The five routes to the factory chimes, and which one we chose. |
| `docs/design/architecture.md` | Star map, phases, verified PID appendix. |
| `docs/registry-format.md` | **The community data format.** Why confidence is derived from evidence, and why writes are gated on it. |

## The three facts that explain most decisions

1. **The OBD-II port is a gateway-isolated diagnostic stub.** 120 Ω at pins
   6/14 (one terminator), and zero broadcast traffic on an error-free line.
   Nothing to overhear there — everything must be *asked for*. Don't
   re-debug the recon firmware's silence; it's correct.

2. **`22 xx00` is a support bitmask.** Four bytes, one bit per identifier,
   covering the next 32, last bit chaining onward — the same convention
   mode-01 PID `00` uses. So 65,536 identifiers cost ~256 requests to map,
   not 65,536.

3. **An ELM327 in protocol 6 only receives `0x7E8–0x7EF`.** Every body module
   is outside that window and gets discarded *in hardware*. `ATCF 700` +
   `ATCM 700` widens it. Without this the car looks silent while it's
   answering — this bug was found and fixed twice, once in the CLI and once
   in the app.

## The headline result

**`22 104E` on module `0x75A` is the rear gate.** `FF` open, `00` shut.
Measured 2026-07-30 by enumerating the body integrated unit with the tailgate
shut, open, and then the passenger door open instead — the third state is
what separated it from two impostors.

Subaru publishes none of this. There is no table to look up; every proprietary
identifier here was measured.

## Components

- **Maia** — core library. ELM327 protocol, PID catalogue, DTCs, freeze
  frames, `ProprietarySignal` (mode 22), `DIDScan` (ISO-TP + UDS parsing),
  `VehicleRegistry`, swappable `OBDTransport`.
- **Electra** — bench simulator. Fake car behind a fake ELM327, plus
  ESP32 firmware that plays scenarios.
- **Alcyone** — the SwiftUI app. Tabs: Dashboard, Diagnostics, Alerts,
  Chimes, Vehicle, **Modules**, **Discover**, Drives. Modules browses the
  registry; Discover runs capture → change one thing → capture → name it,
  from the passenger seat.
- **Sterope** — *observational* alert rules, and *interventional* chime
  policies. Different features; see below.
- **Celaeno** — archives. Fault events survive code clearing, drive logs,
  and `FindingStore` — signals named on the iPad, exported as a patch to fold
  back into the registry (the bundle is read-only at runtime, and a driveway
  guess hasn't met the registry's measured-dated-evidenced bar anyway).
- **Merope** — ESP32-S3 CAN tap. `firmware/merope/`, PlatformIO.
  `lib/merope_core` is portable host-tested C.

## Architectural rules

1. **Transports are swappable.** Dongle, emulator and ESP32 all implement
   `OBDTransport`. Proved twice: the iPad connected to an ESP32 impersonating
   an ELM327 with zero app changes.
2. **Alerts and chimes are different things.** An alert is observational —
   we watch a number and decide whether it's worth mentioning. A chime is
   interventional — a policy for a noise the car already makes. Re-raising a
   warning the car already gives is duplication, not mediation.
3. **Merope transmits when Brian wants it to.** Listen-only is a *mode* for
   recon, not a policy. His car, his call — don't reintroduce a read-only
   rule as if it were a constraint.
4. **Provenance is tracked.** Measured / standard / community / inferred /
   invented are different kinds of true and never render the same.

## Single sources of truth

- `Sources/Maia/Resources/registry/<platform>.json` — what a platform
  exposes. Format spec in `docs/registry-format.md`. Bundled so the app reads
  it; `pleiades registry` renders `docs/SIGNALS.md`; `RegistryDriftTests`
  asserts it agrees with `ProprietarySignal`. Editing one without the other
  fails the bench.

  **Confidence is derived, never asserted.** A contribution is an
  *observation* — what someone did and what happened — and confirmed means
  either seen to change and change back, or reproduced by a second
  contributor. You cannot mark something confirmed; you record evidence good
  enough that it becomes confirmed.

  **`access.write` requires `confidence: confirmed`**, enforced by test.
  Reading a misidentified identifier costs a misinterpreted number; writing to
  one can misconfigure a restraint system on a stranger's car.
- `docs/capture-procedures.json` — scripted capture sessions.
- `Sources/Maia/ProprietarySignal.swift` ↔ `firmware/merope/lib/merope_core/
  include/merope_frames.h` — identifiers must match; nothing reconciles them
  at runtime.

## Commands

```sh
./scripts/bench.sh                       # everything: Swift + C + registry check
swift run alcyone                        # the app, locally on macOS
swift run pleiades registry              # regenerate docs/SIGNALS.md

# At the car — Brian runs these himself, see TCC below
./scripts/did-procedure.sh doors         # scripted capture session
./scripts/did-enum.sh --module 75A --tag "gate closed"
./scripts/did-map.sh                     # identify modules, probe page markers
./scripts/ble-probe.sh                   # dongle first-contact
./scripts/can-sniff.sh inventory --decode  # raw CAN via the CANable

swift run pleiades compare a.json b.json # diff two snapshots, no car needed
```

## Landmines

- **macOS TCC:** commands I run don't inherit Bluetooth permission granted to
  Brian's Terminal. Anything touching CoreBluetooth gets SIGKILLed silently
  in ~1 s with no output. **Hand him the command.**
- **SwiftPM stale test bundle:** changing a struct's stored properties can
  leave the test bundle linked against the old layout — `swift test` then
  SIGSEGVs at load with `swift_retain` on an address that decodes to ASCII.
  `rm -rf .build`. It is not a real memory bug. This has bitten twice.
- **Boolean encoding is per-module.** `0x75A` uses `00`/`FF`; `0x788` uses
  `01`/`02`. A "non-zero means true" decoder reports every unfastened
  seatbelt as fastened.
- **`5C` oil temp is supported; `5E` fuel rate is not.** Settled.
- **One transceiver has its 120 Ω removed** — that's the car-side unit. The
  other stays terminated for the bench.
- `pio device monitor` crashes on Homebrew Python 3.14 — use `cat /dev/cu.*`.
- ESP-IDF ignores `build_src_filter`; entry points use `MRP_APP_*` guards.
- **SwiftUI:** gauge arithmetic chained in modifiers blows up type-check time
  — hoist typed locals, use concrete `Shape` structs. Wheel pickers are
  unusable past ~10 items; use a searchable sheet. The package targets macOS
  13, so no `ContentUnavailableView`.
- The mytrile DTC dataset is corrupt (row-drifted); we use Wal33D's.
- Bad dupont jumpers cost hours during bench bring-up. Solid core for the
  bench, **stranded** for anything in the car.

## Working style

- **Docs are part of the work.** A finding that isn't written down is a
  finding that gets rediscovered. Commit messages carry the reasoning.
- **Record what we don't know** as carefully as what we do — the registry's
  open questions are the work queue.
- **Nothing is confirmed on one observation.** A signal that moves once is a
  correlation; one that moves and returns is a measurement. `0x1024` looked
  like the gate for three runs before the volatile filter caught it drifting.
- **Tag every capture.** The belt findings are stuck at `candidate` purely
  because the procedure was improvised.
- Brian works at Galaxy Digital; this is personal OSS. Keep employer material
  out of it.

## Linear

The Shed → project **pleiades**, SHED-65..95.
