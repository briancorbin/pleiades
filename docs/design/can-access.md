# CAN access — where to read, where to cut

Worked out 2026-07-31, after the OBD port turned out to be a diagnostic stub
and the question became *where else*. Companion to `chimes.md`, which covers
what to do once you're on the wire.

## The topology, corrected

The car is not one CAN bus. It's several independent buses, joined by a
gateway module.

```
                  ┌────────────────┐
                  │    GATEWAY     │   one module, one connector
                  └──┬────┬────┬───┘
                     │    │    │
     ┌───────────────┘    │    └───────────────┐
     │                    │                    │
  body CAN pair      main CAN pair       OBD stub pair
     │                    │                    │
  ─┬─┴──┬──────┬─      ─┬─┴────┬──────┬─       │
   │    │      │        │      │      │        │
 [BIU][clstr][keyless] [ECM][EyeSight][VDC]  [OBD-II port]
```

Three things this picture gets right that the intuitive one doesn't:

1. **A bus is a party line, not a star.** Every module on a segment is wired
   in parallel across the same two wires. No master, no hub, no addressing —
   a frame ID names the *message*, not a recipient. Everyone hears
   everything and filters for what they want.

2. **The gateway is a node on each bus, not a junction they pass through.**
   It has one CAN controller per network and relays selected frames between
   them *in firmware*, via a routing table. Traffic between two modules on
   the same bus never touches it.

3. **The OBD port is its own pair off the gateway.** Measured, not assumed:
   pins 6/14 read 120 Ω — a single terminator, so a stub, not a bus. The
   routing table forwards diagnostics onto it and nothing else, which is
   exactly what recon saw.

Frame ids encode priority — lowest wins arbitration. That's why powertrain
traffic is `0x040`/`0x13A` and every diagnostic address is `0x7xx`: a scan
tool must never delay a brake message.

## Read at the gateway. Cut at the listener.

The temptation is to intervene at the most *central* point. On a broadcast
bus the right target is the narrowest chokepoint on the **specific
conversation** you want to change — centrality buys reach you don't need and
responsibility you don't want.

| Goal | Where | Why |
|---|---|---|
| See everything | gateway connector | every bus in the car lands there; back-probe, modify nothing |
| Read one bus | EyeSight connector | `0x3AC` BodyInfo is on the main bus; behind the mirror, no dash work |
| Intercept a chime input | at the cluster | only the cluster should be wrong about the gate |
| Mute/replace a sound | cluster speaker lead | analog, unrelated to CAN |

Two rejected alternatives, and why:

- **Cut at each module.** Cutting at the *source* hides a signal from every
  listener, including the dome light, the head-unit door display and the
  keyless lock logic. Cutting at the *listener* affects one. Also: N bypass
  relays, N points of failure, store-and-forward latency in front of VDC and
  airbag traffic, and a whole-car teardown.
- **Cut the gateway's links.** Does nothing if the cluster and BIU share a
  bus, since that traffic never crosses the gateway. And it makes Merope
  responsible for all inter-bus routing — including the diagnostic traffic
  that answers `22 104E`, so it would break our own scan tool unless we
  faithfully reimplement the gateway.

## The open question, and the ten-minute test

**Is the cluster on the same bus as the BIU (`0x75A`)?** That single fact
decides whether route 3b is a mirror-shroud job or a dash teardown, and it
is not yet measured.

Back-probe CAN H/L at the EyeSight connector — pins are in comma's published
`Subaru_C_Harness.pdf` (`commaai/neo`, `car_harness/v3/`) — and listen. Then:

- **Cluster-sourced frames present** (odometer, warning state, unit
  preference) → same segment, and route 3b happens wherever the cluster
  attaches to it.
- **Absent** → a gateway sits between them, and the install changes.
- **`75A` transmitting there while also holding body signals** → it's on
  both networks, which would make "Integ. Unit" the gateway itself.

While tapped, cross-check opendbc's `0x3AC` bit 36 against the confirmed
`22 104E`. Two independent paths agreeing on the same tailgate is a far
stronger decode than either alone.

## Practical notes

- **Back-probe before cutting.** A fine wire into the back of a seated
  terminal reads the bus with zero modification and pulls out in seconds.
  Everything so far has been non-destructive; stay there as long as possible.
- **Bitrates differ per bus.** Powertrain is typically 500 kbit/s, body
  networks often 125k or 250k. The recon firmware already hunts, so let it.
- **Not every pair is CAN.** Doors and small actuators often hang off LIN,
  a single-wire bus. Silence at every bitrate probably means LIN, not a
  broken tap.
- **Termination.** An intact bus measures 60 Ω across the pair — two 120 Ω
  terminators in parallel. Split it and each half keeps one; measure both
  and add resistors so each segment reads 60 Ω, or you get the reflections
  that caused the bench `BUS_OFF`.
- **Stranded wire only** in the car. Solid core work-hardens and cracks
  under vibration.
- **A comma Subaru C harness** ($99) is an inline passthrough at the
  EyeSight connector — no cutting, and it reverts to stock when nothing is
  plugged in, which is the fail-closed behaviour route 3b needs. The
  car-side end is OBD-C, so it needs a breakout to reach Merope's
  transceiver.
