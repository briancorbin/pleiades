<!-- Generated from docs/signal-registry.json by `pleiades registry`. Do not edit by hand. -->

# Signal registry

Everything this car is known to expose, and **how we know it**. Some of
it comes from public standards, some from other people's reverse
engineering, and some was measured in a driveway with a tailgate held
open — those are very different kinds of true, so every row says which.

**Vehicle:** 2022 Subaru Forester Wilderness · FB25D · Subaru Global Platform
**Protocol:** ISO 15765-4 (CAN 11-bit, 500 kbit/s) — ELM327 protocol 6
## Provenance

| Label | Meaning |
|---|---|
| `community` | Third-party reverse engineering. Credible, not verified by us. |
| `inferred` | Reasoned from evidence but never directly tested. Treat as a hypothesis. |
| `invented` | Our own identifier, for bench signals with no known real counterpart. |
| `measured` | We proved it on this car. Requires a date, a method, and a log file. |
| `standard` | Defined by a public standard (SAE J1979, ISO 14229). True for any conforming car. |

## Confidence

| Label | Meaning |
|---|---|
| `candidate` | A specific prediction we haven't tested. Says what would confirm or kill it. |
| `confirmed` | Measured, and discriminated from the alternatives that could have explained the same result. |
| `rejected` | Investigated and ruled out. Recorded so nobody spends an evening on it twice. |
| `unidentified` | The identifier answers. We have no idea what it means. This is the work queue. |

## Modules

16 modules answer diagnostics. **5** identifiers are confirmed.

| Address | Name | Role | Pages | Signals |
|---|---|---|---|---|
| `0x75A` | Integ. Unit | Body integrated unit — doors, gate, lighting, chimes. Prime suspect for also being the CAN gateway. | `01 02 10 11 F1 FF` | 5 named / 191 answer |
| `0x788` | Airbag System | Restraints. Most likely home of the seatbelt buckle switches. | `01 02 10 23 F1 FF` | — |
| `0x75B` | Tire pressure monitor | TPMS — per-wheel pressures. | `01 02 10 F1` | — |
| `0x7BC` | Keyless Access & Push Start (C) | Keyless entry, driver side. Knows door and gate state for locking logic. | `01 02 10 11 12 13 20 30 F1 FF` | — |
| `0x7C9` | Keyless Access & Push Start (P) | Keyless entry, passenger side. | `01 02 10 11 12 13 20 30 F1 FF` | — |
| `0x7E8` | 2.5 DOHC | Engine control module. Answers the standard mode-01 PID set and holds the VIN at F190. | `01 02 10 11 12 13 20 30 74 75 76 77 F1 F4` | — |
| `0x7E9` | Transmission | TCM. Answers mode 01 but was never seen answering mode 22. | — | — |
| `0x78F` | EyeSight | Driver assistance cameras. By far the richest module — 92 pages. | `01 02 10-16 20-2E 30-39 40-49 4A 50-5F 60-6F 70-7C F1 FF` | — |
| `0x71F` | Electric Brake Booster |  | `01 02 10 30 31 32 33 F1 FF` | — |
| `0x74A` | RADAR ASSY B&S LH | Blind-spot radar, left. | `01 02 10 F1 FF` | — |
| `0x74B` | RADAR ASSY B&S RH | Blind-spot radar, right. | `01 02 10 F1 FF` | — |
| `0x77E` | Data Communication Module | Telematics. | `01 02 10 11 12 F1 FF` | — |
| `0x78E` | Sonar system | Parking sensors. | `01 02 10 F1 FF` | — |
| `0x7B8` | VDC/Parking Brake System | Stability control and electronic parking brake. | `01 02 10 20 F1 FF` | — |
| `0x7DD` | MFD | Multi-function display. | `01 02 10 F1 FF` | — |
| `0x78B` | (declined to answer F197) | Unknown. The only module that would not give a name. | `02 03 10 A0 F1 FF` | — |

### `0x75A` — Integ. Unit

| Identifier | Signal | Confidence | Provenance | How we know |
|---|---|---|---|---|
| `0x104E` | Rear gate — true = `FF` | `confirmed` | `measured` | Enumerated 0x75A three times: gate shut, gate open, passenger door open. 104E moved for the gate and ignored the door. (`logs/did-20260730-190933.json, -191135, -191652`) The signal this whole project was started to get. |
| `0x104B` | Door front right — true = `FF` | `confirmed` | `measured` | Same three-state diff, inverted: tracked the passenger door and ignored the gate. (`logs/did-20260730-191652.json`) |
| `0x1073` | Any opening — true = `FF` | `confirmed` | `measured` | Went true for both the gate and the passenger door — an aggregate, which is how it was told apart from the specific signals. (`logs/did-20260730-191652.json`) |
| `0x1117` | Rear gate (page 11 mirror) | `confirmed` | `measured` | Tracked the gate identically to 0x104E across all three states. (`logs/did-20260730-191652.json`) Page 0x11 mirrors page 0x10. Kept as a cross-check; not polled. |
| `0x1116` | Door front right (page 11 mirror) | `confirmed` | `measured` |  (`logs/did-20260730-191652.json`) |
| `0x104A` | Door front left | `candidate` | `inferred` | Neighbour of the two confirmed hits; sat at 00 through all three states. Never tested with this door open. Open the driver's door alone and re-enumerate to promote or kill it. |
| `0x104C` | Door rear left | `candidate` | `inferred` | Neighbour of the confirmed hits; 00 throughout. |
| `0x104D` | Door rear right | `candidate` | `inferred` | Neighbour of the confirmed hits; 00 throughout. |
| `0x1024` | (unknown — false positive) | `rejected` | `measured` | Moved A6 → A5 on the first diff and looked like a candidate. Across three runs the two-pass volatile filter caught it drifting on its own. Recorded so nobody re-investigates it. |

### `0x788` — Airbag System

> **Not yet explored.** Enumerate with belts unbuckled, then buckled. Page 23 is its distinctive one.


### `0x75B` — Tire pressure monitor

> **Not yet explored.** Enumerate, then let pressure out of one tyre and re-enumerate to map corner to identifier.


### `0x78B` — (declined to answer F197)

> **Not yet explored.** Try F187 (part number) or F18C (serial) to identify it. Page A0 is unique to this module.


## What we don't know yet

The work queue. Each of these is answerable with the tools already built.

**Is the instrument cluster on the same bus as 0x75A?**

- *Why it matters:* Decides whether chime input interception is a mirror-shroud job or a dash teardown. Cutting at the gateway does nothing if the BIU and cluster share a bus, because that traffic never crosses it.
- *How to answer:* Back-probe CAN H/L at the EyeSight connector and watch for cluster-sourced frames — odometer, warning state, unit preference.

**Is 0x75A also the CAN gateway?**

- *Why it matters:* The module holding the gate bit would also be routing between networks — which changes what cutting near it does.
- *How to answer:* If 0x75A transmits on the main bus while also holding body signals, it is on both networks.

**What is module 0x78B?**

- *Why it matters:* The only module that refused to answer F197. Unknown capability on the car.
- *How to answer:* Try F187 (part number) or F18C (serial). Page A0 is unique to it and worth enumerating.

**Which identifiers carry the seatbelt buckle switches?**

- *Why it matters:* Second-most-wanted chime after the gate, and currently invented rather than measured.
- *How to answer:* Enumerate 0x788 belts-unbuckled, then buckled. Page 23 is its distinctive one.

**Which identifiers carry per-wheel tyre pressure?**

- *How to answer:* Enumerate 0x75B, let pressure out of one tyre, re-enumerate. The corner that moves names itself.

**Do the other three doors match the predicted neighbours?**

- *Why it matters:* 0x104A/104C/104D are inferred, not measured — the registry currently claims three things it hasn't proven.
- *How to answer:* Open one door at a time and re-enumerate 0x75A.

**Are engine internals present on the main bus at all?**

- *Why it matters:* opendbc decodes only what openpilot needs — coolant, fuel trims, oil temp are absent from its table. If the bus carries them undecoded, a tap replaces PID polling entirely; if not, mode 01 stays.
- *How to answer:* Tap, capture, and look for frames that correlate with known PID values.

**What are the other 186 identifiers on 0x75A?**

- *Why it matters:* 191 answer, 5 are identified. The rest are the largest single pool of unknown vehicle state we have access to.
- *How to answer:* Same mark/diff method, one physical change at a time. Lights, wipers, ignition position, gear selector, handbrake.


## Buses

| Bus | Access | Carries | Provenance |
|---|---|---|---|
| OBD-II diagnostic stub | OBD-II port, pins 6/14 | Request/response diagnostics only — no broadcast traffic whatsoever | `measured` |
| main / powertrain CAN | EyeSight camera connector, behind the rear-view mirror | Engine, chassis, and (per opendbc) BodyInfo + Dashlights | `community` |
| body CAN | not yet located | Presumed home of the BIU, keyless, TPMS | `inferred` |

- **OBD-II diagnostic stub** — 120 Ω across pins 6/14 (one terminator, so a stub) and zero broadcast frames observed on an error-free line

- **main / powertrain CAN** — Reachable with a comma 'Subaru C' harness as an inline passthrough, or by back-probing. Pinout: commaai/neo car_harness/v3/Subaru_C_Harness.pdf

- **body CAN** — Whether the instrument cluster shares a bus with 0x75A is the open question that picks the route-3b install location. See docs/design/can-access.md.

## Broadcast frames (not reachable at the OBD port)

Community-decoded, from opendbc. These need a bus tap — the OBD port carries no broadcast traffic on this car.

| CAN ID | Frame | Signals | Provenance |
|---|---|---|---|
| `0x3AC` | BodyInfo | DOOR_OPEN_FL, DOOR_OPEN_FR, DOOR_OPEN_RL, DOOR_OPEN_RR, DOOR_OPEN_TRUNK, BRAKE, LOWBEAM, HIGHBEAM, FOG_LIGHTS, WIPERS | `community` |
| `0x390` | Dashlights | SEATBELT_FL, LEFT_BLINKER, RIGHT_BLINKER, UNITS, ICY_ROAD, STOP_START | `community` |
| `0x040` | Throttle | Engine_RPM, Throttle_Pedal, Throttle_Cruise, Neutral | `community` |
| `0x13A` | Wheel_Speeds | FL, FR, RL, RR | `community` |

- **BodyInfo** — DOOR_OPEN_TRUNK is bit 36 — the broadcast counterpart of our measured 22 104E. Cross-checking the two is a free validation of both.

## Conventions this car follows

Hard-won rules. Each one cost an evening to find and saves the next one.

**22 xx00 is a support bitmask** — `measured`, 2026-07-30

Four bytes, one bit per identifier, covering the 32 that follow, with the last bit chaining to the next block — the same convention mode-01 PID 00 uses. 0x74A answered 00 00 E0 50 at 0100, predicting 0111 0112 0113 011A 011C, which is exactly what it went on to answer.

> 65,536 identifiers cost ~256 requests to map instead of 65,536.

**An ELM327 in protocol 6 only receives 0x7E8–0x7EF** — `measured`, 2026-07-30

The legislated OBD response window. Every body module is outside it and gets discarded in hardware. ATCF 700 + ATCM 700 widens it.

> Without this a scan sees only the engine, and the car looks silent when it is answering.

**This car answers FF for true, not 01** — `measured`, 2026-07-30

> A decoder testing `== 1` reads every open tailgate as closed.


## Sources

| Source | License | What it gives us |
|---|---|---|
| Measured on the car | — | Enumerate a module, change one physical thing, enumerate again, diff. See docs/design/did-discovery.md. |
| [SAE J1979 / ISO 15031-5 standard OBD-II PIDs](https://en.wikipedia.org/wiki/OBD-II_PIDs) | — | Hand-coded into Sources/Maia/PID.swift. Universal across post-1996 vehicles. |
| ISO 14229 (UDS) standardised identifiers | — | The F1xx block — VIN, part numbers, system name. Same on any UDS-compliant module. |
| [Wal33D/dtc-database](https://github.com/Wal33D/dtc-database) | MIT | 9,415 generic + 93 Subaru trouble codes, vendored to Sources/Maia/Resources/dtc-codes.json. mytrile/obd-trouble-codes was rejected for systematic row drift. |
| [commaai/opendbc — subaru_global](https://github.com/commaai/opendbc/tree/master/opendbc/dbc/generator/subaru) | MIT | Broadcast CAN frames on the main bus. Covers what openpilot needs, so plenty of engine internals are absent. Not reachable at the OBD port on this car. |
| No public source exists | — | Subaru publishes no mode-22 identifier table. Their dealer tool knows these internally. No community dataset covers them either. |
