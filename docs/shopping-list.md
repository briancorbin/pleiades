# pleiades — full hardware shopping list

*Everything physical between here and the finished platform, by phase.
Check things off as they land.*

## ✅ Sorted (2026-07-28)

- [x] 3× **ESP32-S3 N16R8** (Hosyond 3-pack) — Merope, Electra-on-a-wire, spare
- [x] 2× **Waveshare SN65HVD230** CAN transceivers (onboard 120 Ω termination —
  ideal for the desk bus; desolder on whichever board ends up tapping the car)

## Phase 1 — Alcyone meets the real car (~$35)

- [x] **Vgate iCar Pro BLE 4.0** (~$35) — the iOS-compatible dongle. Gets the
  real FB25 PID map and live gauges in the driveway. **Post-SHED-93 note:** it
  is no longer an install component — Merope becomes the single in-car
  gateway. Keep the dongle as a known-good reference for validating Merope's
  request/response against something proven.

## For the single-gateway end state (SHED-93/94)

**Transmitting needs no new hardware** — it's `TWAI_MODE_LISTEN_ONLY` →
`TWAI_MODE_NORMAL`. The transceiver's driver stage is already there. What's
listed below is for the *car install*, not for TX.

## Merope desk bench — ✅ fully covered

- [x] Jumper wires, breadboards, resistors — Brian's existing electronics stash
- [x] Termination — covered by the Waveshare boards

## Merope goes in the car (~$35)

- [x] **OBD-II Y-splitter** (male → 2× female, ~$10) — Merope on one leg, port
  stays free for the dongle / state inspection
- [x] **12 V→5 V buck converter** (~$10) — get a decent automotive-tolerant one
  (input rated ≥ 24 V for load-dump headroom), not a bare LM2596 board
- [x] **Inline fuse** (~$8) — blade-fuse holder + 1–2 A fuse on the 12 V feed;
  pin 16 is always-hot battery
- [x] **Small project box** (~$8) + 3M Dual Lock / velcro + zip ties — behind
  the dash trim, invisible from the cabin (Merope is the star that hides)
- [ ] **22 AWG *stranded* wire** (~$10) — for anything that lives in the car.
  Solid core is right for a breadboard and wrong in a vehicle: engine
  vibration work-hardens solid conductors until they crack, months later,
  presenting as an intermittent fault. Stranded for the harness.
- [ ] Heat shrink + a little wire loom, if the bin is low
- [ ] **Desoldering wick** (~$5) — to lift the 120 Ω termination off the
  car-side transceiver. Check the board first; some VP230s put termination on
  a solder jumper and it's free.

## Alcyone lives in the cabin (~$25–45)

- [ ] **OBD-II male pigtail** with flying leads (~$8) — **required**, not
  optional: the Y-splitter gives two *female* sockets, so Merope needs a male
  connector to tap pins 6/14 (CAN-H/L), 16 (+12 V) and 4/5 (GND)
- [ ] **USB battery pack** — powers Merope during recon so stage 1 never
  touches the car's 12 V (probably already own one)

## Alcyone lives in the cabin (~$25–45) — continued

- [ ] **iPad mount** (~$25–40) — dash or CD-slot style for the Forester; pick
  after deciding where the iPad rides
- [ ] USB-C cable long enough to reach the car's power — probably owned

## Optional / later

- [ ] microSD breakout (~$5) — only if Merope graduates from event capture to
  continuous drive logging
- [ ] Aftermarket **oil-pressure sender** — the one number no tap can conjure
  (the FB25 only has a switch); a Sterope-era decision, needs a mechanical
  install at the oil galley
- [ ] **Cheap 8-channel logic analyzer** (~$15) — optional, but pays for
  itself the first time you need to see whether bits are actually leaving a
  pin (see the 2026-07-30 bring-up)

## Assumed on hand

Soldering iron, multimeter, wire strippers, USB-C cables, screwdrivers
(including the one that famously tricks the gate latch).

**Remaining core spend: ~$65 (dongle + Y-splitter + buck + fuse + box).
Everything incl. iPad mount: ~$100. Desk bench: $0 — ready on arrival.**
