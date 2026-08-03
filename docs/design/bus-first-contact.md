# Bus first contact — reading a real CAN bus, no OBD port

The OBD-II port is a gateway-isolated diagnostic stub: request/response only,
no broadcast traffic, nothing to overhear. Everything learned through it so
far was *asked for*, one identifier at a time, through an ELM327 that spent
three separate bugs pretending the car was silent.

This is the other way in. Tap a real bus, transmit nothing, and watch what
the car says on its own.

**What you lose without the port:** trouble codes, freeze frames, and code
clearing are request/response by nature and don't exist on a bus. The five
confirmed mode-22 identifiers aren't readable this way either — but `0x3AC`
bit 36 should track the tailgate, and cross-checking it against `22 104E` is
worth more than either alone.

## Phase 0 — rehearse on the bench, before the car

Do this at your desk. It costs nothing and it removes every variable except
the car.

The Merope/Electra bench already transmits real CAN at 500 kbit/s. Point the
adapter at it:

1. **Terminator switch ON** — you're an end of a short bench bus.
2. CANable `CAN_H` → bench `CAN_H`, `CAN_L` → `CAN_L`. Ground optional on a
   bench sharing a supply; on the car, don't bother — CAN is differential.
3. Power the bench, then:

```bash
cd ~/Programming/pleiades && ./scripts/can-sniff.sh inventory --seconds 3
```

**Expect:** frame ids at 500 k, and silence at the other three bitrates.

That single run validates the adapter, listen-only mode, the bitrate hunt,
your probe technique, and the decode path. If it fails here it would have
failed in a car park, in the dark, with a trim panel in your lap.

Then rehearse the actual method — `watch`, flip a scenario on the bench with
BOOT, and confirm the diff catches it:

```bash
./scripts/can-sniff.sh watch --tag "bench scenario change"
```

## Phase 1 — find the bus

Two places worth tapping, and they answer different questions.

### 1a. The EyeSight connector — easier, one bus

Behind the rear-view mirror under a snap-off shroud. Pin assignments are in
comma's published `Subaru_C_Harness.pdf` (`commaai/neo`, `car_harness/v3/`).

Start here. Not because it's the better tap, but because a **known-good
access point with a published pinout** turns a first run into a yes/no. If a
harder location later comes back silent, you'll know it's the location and
not the technique.

### 1b. The gateway — harder, every bus at once

The gateway is the only place in the car where **every network lands on one
connector**. Nowhere else gives you that, and it's the definitive answer to
questions the topology doc currently guesses at: how many buses this car
actually has, and which one the instrument cluster sits on.

**Finding it needs no wiring diagram.** With the car off, ohm across each
twisted pair on a candidate module's connector:

| Across a pair | What it is |
|---|---|
| **60 Ω** | a terminated CAN bus — this is one you want |
| **120 Ω** | a stub off the gateway (this is what the OBD port measures) |
| anything else | not CAN — LIN, power, or a discrete signal |

Two minutes with a multimeter identifies every CAN pair on a connector, with
nothing connected and nothing powered. It's the same measurement that proved
the OBD port was a stub, used as a search tool instead of a diagnosis.

**Where to look:** if `0x75A` "**Integ**. Unit" is the gateway — its name and
its 191 identifiers both hint that way — it's the body integrated unit, which
on a Forester generally lives behind the driver's-side lower dash panel. Trim
clips rather than a teardown. That location is inferred, not measured: you're
looking for a module with several twisted pairs landing on it, then ohming
them.

**One adapter, one pair at a time.** Comparing two buses means probing pair A,
noting what's there, then pair B. Sequential and slower, but it answers the
cluster question either way. (Merope could be a second interface later —
watching two buses at once is what a transparent gateway has to do anyway,
and it's hardware you already own.)

### Either way

**Terminator switch OFF.** The car's bus already has its two 120 Ω. A third
drops it to 40 Ω and the transceivers can't pull dominant.

**Back-probe, don't cut.** Fine wire into the back of the seated terminal.
The connector stays mated, the car stays stock, and it pulls out in seconds.

Ignition **ON**, engine off is fine to start.

```bash
./scripts/can-sniff.sh inventory --seconds 5 --decode
```

### Reading the result

| What you see | What it means |
|---|---|
| ~27 ids at 500 k, `BodyInfo` and `Dashlights` among them | you're on the main bus. Proceed. |
| Ids at a *different* bitrate | fine — note it and pass `--bitrate` from here on |
| Silence at all four | see the failure list the tool prints. Swapped pair is the most common and is harmless. |
| Ids, but none decode | a real bus that isn't the one opendbc describes. Still useful; the diff method doesn't need names. |

Silence with the car **asleep** is normal — buses go quiet. Open a door and
try again before concluding anything.

## Phase 2 — answer the open questions

These are cheap and they're what the whole install plan is waiting on.

**Is the cluster on this bus?** Watch for frames the *cluster* originates —
odometer, warning-lamp state, unit preference. If cluster traffic is here,
route 3b happens at a connector you can reach without a dash teardown. If
it's absent, a gateway sits between them and the plan changes.

**Does `0x3AC` bit 36 track the tailgate?**

```bash
./scripts/can-sniff.sh decode --ids 3AC,390
```

Open the tailgate and watch `DOOR_OPEN_TRUNK` flip. That's an independent
confirmation of `22 104E` — two different paths, two different protocols,
one tailgate. It's also the moment opendbc's community data gets verified
against your own measurement rather than trusted.

**Does `0x75A` transmit here?** If the body integrated unit is on this bus
while also holding the body signals, it's on both networks — which would make
"Integ. Unit" the gateway.

## Phase 3 — the mark/diff runs

Same method as the mode-22 work, except a bus broadcasts everything at once,
so one capture covers every signal rather than one identifier.

```bash
./scripts/can-sniff.sh watch --tag "front left door"
```

It prompts for a baseline, waits while you change one thing, captures again,
and prints what moved with `^^` under the changed bytes. Per-byte stability
filtering means the rolling counters and checksums that ride in every frame
don't drown the answer.

Work the same list the scripted procedures use — one thing at a time, put it
back between each:

1. Each door, then the tailgate
2. Each seatbelt
3. Lights: parking, low, high, fog, hazards, indicators
4. Brake pedal, parking brake, gear selector, wipers

Every one of those is a signal nobody has published for this platform.

## What to bring home

The captures, and specifically **which frame and which byte** moved for each
change. That's a registry contribution: an observation with a date, a method,
and evidence.

Anything seen to change *and change back* is confirmed. Anything seen once is
a candidate — the tool records the difference, and so does the registry.

## What to bring with you

- The CANable, and a laptop
- Back-probe pins or fine solid wire
- Plastic trim tools for the shroud
- The harness pinout, downloaded before you leave — no signal in a car park
- **A multimeter** — it does double duty now: 60 Ω confirms a pair is a
  live CAN bus before you connect, and sweeping an unknown connector for
  60 Ω pairs is how you find the gateway's buses without a wiring diagram

## If you want diagnostics too, later

A raw CAN interface can send UDS requests as well as listen — it's a strict
superset of what the dongle does, without the receive filter or the timing
guesswork. That means `22 104E` is readable from the bus as well, and the
whole mode-22 toolchain could run over the CANable at roughly fifty times the
speed.

It requires transmitting, which is the opposite of everything above. Worth
doing deliberately, on a parked car, once the passive picture is complete.
