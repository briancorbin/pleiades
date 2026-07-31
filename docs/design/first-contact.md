# First contact — Merope meets the car

*The driveway session. Listen only, battery powered, nothing permanent, and
no 12 V touched.*

## What this session is for

Answer three questions, in order:

1. Can Merope see the car's bus at all?
2. What frames are on it?
3. **Which frame carries the rear gate latch?** (and belts, doors, TPMS)

Nothing gets installed. Nothing gets cut. If the answer to (1) is no, you
unplug and we think again.

## Before you go outside

**1. Remove the 120 Ω termination from this transceiver.** Non-negotiable.
The car's bus is already terminated at both ends; a third resistor drops the
bus to ~40 Ω and can degrade signalling *for every module on it*. Check the
board first — some VP230s put termination on a solder jumper, in which case
it lifts off free. Otherwise desolder it or lift one leg.

Use the *other* transceiver for the desk bench and keep this one as the
car-side unit, permanently unterminated.

**2. Flash the recon firmware.**

```sh
cd firmware/merope
pio run -e recon -t upload --upload-port /dev/cu.usbmodemXXXX
```

**3. Self-test it first.** `pio run -e selftest -t upload …`, confirm green,
then flash recon. Two minutes now beats debugging in a cold driveway.

**4. Power from a USB battery pack.** Not the car. Stage 1 never touches
pin 16.

## Wiring at the OBD port

Three wires. The port is under the dash on the driver's side.

| OBD-II pin | Signal | → |
|---|---|---|
| 6 | CAN-H | transceiver `CANH` |
| 14 | CAN-L | transceiver `CANL` |
| 4 or 5 | Ground | transceiver `GND` |

Pin 16 (+12 V) stays untouched this session.

You can reach the pins with an OBD male pigtail, or by carefully
backprobing the port's sockets with solid-core wire for a one-off session.
The pigtail is tidier and required for the permanent install anyway.

## The session

1. Ignition **on** (engine running is best — more modules awake).
2. Watch the serial console. Within 10 s you should see an inventory of
   frame ids. Violet LED = frames arriving; **red = nothing seen**, which
   means check wiring, ignition, and that the termination really came off.
3. Let it run a minute so the inventory settles.
4. **Press BOOT** — snapshots every frame's current bytes (LED goes blue).
5. **Do one thing.** Open the rear gate. Just that.
6. **Press BOOT again** — it prints every frame id that changed, with `^^`
   under the specific bytes that moved.
7. Repeat for each signal: unbuckle the belt, open a door, press the brake.

One action per mark/report cycle. Two actions at once and you can't tell
which byte belonged to which.

## What to bring home

The changed-frame reports. `0x??? byte N` for gate, belts, doors — that's
the decode table, and it replaces the invented layouts in `merope_frames.c`.
Everything above that table — ring buffer, fault windows, BLE, the app —
already works and doesn't change.

## Then what

- Cross-check the ids against opendbc's Subaru Global Platform DBC. Community
  work may name them already; verify rather than trust.
- If the gate latch **isn't** visible at the OBD port, it's behind the body
  gateway, and the chime work needs a tap closer to the cluster. That's the
  single most important thing this session tells us.
- Only after data is proven: the permanent 12 V install (SHED-73).

## What actually happened — 2026-07-30

The second bullet. Pins 6/14 read **120 Ω**, not 60, and passive listening saw
**no broadcast traffic at all** on an otherwise error-free line. The port is a
gateway-isolated diagnostic stub: it carries request/response only, and there
is nothing there to overhear.

The mark/diff procedure above is still exactly right — it just moves up a
layer, from CAN frame ids to mode-22 identifiers. See **`did-discovery.md`**,
which is this document's sequel and the current live procedure.

The dash tap isn't off the table, but it's now the fallback rather than the
plan: it's invasive, and the car answers `22 01xx` from fourteen modules
without anyone removing a panel.
