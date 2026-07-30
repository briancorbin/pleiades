# pleiades — full hardware shopping list

*Everything physical between here and the finished platform, by phase.
Check things off as they land.*

## ✅ Sorted (2026-07-28)

- [x] 3× **ESP32-S3 N16R8** (Hosyond 3-pack) — Merope, Electra-on-a-wire, spare
- [x] 2× **Waveshare SN65HVD230** CAN transceivers (onboard 120 Ω termination —
  ideal for the desk bus; desolder on whichever board ends up tapping the car)

## Phase 1 — Alcyone meets the real car (~$35)

- [x] **Vgate iCar Pro BLE 4.0** (~$35) — the iOS-compatible dongle. This is the
  gate for the real FB25 PID map, the CoreBluetooth transport, and live gauges
  in the driveway. Nothing else substitutes (iPads can't do BT-Classic).

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
- [x] Hookup wire + heat shrink — existing stash

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
- [ ] Second OBD male pigtail (~$8) — bench-testing the Y-splitter wiring
  without the car

## Assumed on hand

Soldering iron, multimeter, wire strippers, USB-C cables, screwdrivers
(including the one that famously tricks the gate latch).

**Remaining core spend: ~$65 (dongle + Y-splitter + buck + fuse + box).
Everything incl. iPad mount: ~$100. Desk bench: $0 — ready on arrival.**
