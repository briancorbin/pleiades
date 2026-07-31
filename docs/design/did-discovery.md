# DID discovery — asking the car what it won't say

*Written after first contact, 2026-07-30, which answered the question that
made this document necessary.*

## The finding this exists because of

The plan was to park a CAN sniffer on the OBD-II port and listen. That plan
is dead, and it's worth being precise about why, because the evidence is
unambiguous and re-deriving it costs an afternoon.

Two measurements, taken on the real car:

- **Pins 6 and 14 read 120 Ω**, not 60. A live CAN bus is terminated at both
  ends, and two 120 Ω resistors in parallel measure 60. Reading 120 means
  there is exactly one terminator on the other side of that connector.
- **Passive listening saw zero broadcast traffic and zero errors.** Not a
  noisy bus we failed to decode — silence, on a healthy line. Every frame that
  ever appeared was diagnostic: `0x7DF` requests going out, module addresses
  answering back.

Together those say the port is a **gateway-isolated diagnostic stub**. It is
not a tap onto the car's real buses. It's a service window that a gateway
module holds open, and it passes request/response traffic only.

So the gate latch is not there to be overheard. Nothing is. Anything the car
knows and won't volunteer has to be **asked for**.

## What the car does answer

It answers mode 22, `ReadDataByIdentifier`, and generously. During recon,
**14+ module addresses** responded to `22 01xx` requests:

```
71F  74A  74B  75A  75B  77E  788  78B  78E  78F  7B8  7BC  7C9  7DD
```

Those are body, chassis, and comfort modules — the ones that know about
latches, buckles, and tire pressures. The `0x01xx` identifier range is live
across all of them.

What we don't have is the *meaning* of any identifier. Subaru publishes none
of this. There is no table to look up.

## How you find out anyway

Change one thing about the car, and watch what changes in its answers.

That's the whole method, and it works because a data identifier is a stable
address: `22 0142` returns the same field every time, so if that field's bytes
differ between two sweeps, something moved it. Do only one thing between
sweeps and there's only one candidate for what.

```bash
./scripts/did-scan.sh --tag "gate closed"
```

Walk back, open the tailgate, come back.

```bash
./scripts/did-scan.sh --tag "gate open"
```

The second run finds the first in `logs/` on its own and prints the diff:

```
  22 0142 @ 74A   changed
     before  01 04 00 00
     after   01 04 00 01
                       ^^
```

That's the gate. Byte 3 of identifier `0x0142` on module `0x74A`.

The `^^` marker is deliberately the same notation the recon firmware uses for
changed CAN bytes — you end up reading both in the same afternoon and they
should not require switching mental gears.

### Confirm before believing

One diff is a correlation. Close the gate and sweep a third time; if the byte
returns to `00`, it tracks. If it doesn't, you found a counter that happened
to tick, and the tag on the third sweep is what tells you so.

## The volatile problem, and why passes default to 2

A car is never still. Odometers count, voltages sag, timers run, temperatures
drift. A naive sweep-and-diff on a running vehicle turns up dozens of
identifiers that changed for no reason anyone caused, and the one byte that
tracks the gate is invisible in the noise.

So each sweep runs **twice by default, at the same vehicle state**. Anything
that disagrees between those two passes moved on its own, gets flagged
`volatile`, and is excluded from the diff — it cannot be evidence about
something nobody did to the car during it.

`--include-volatile` shows them anyway. Reach for it only if the range looks
suspiciously empty; a slow counter can hide inside a fast one's noise.

## Scope: 256 identifiers, not 65,536

The default range is `0x0100–0x01FF`, because that's where the car was
observed answering. A full 16-bit sweep is 65,536 requests at roughly a
quarter-second each — around four and a half hours per pass, nine per sweep.
Don't.

If `0x01xx` comes up empty for a signal, widen deliberately: `0xF1xx` holds
standardized identifiers (VIN, part numbers, software versions) and is worth a
look for module fingerprinting. Otherwise, prefer more *states* over more
*range* — a second and third confirmed action teaches more than another 256
identifiers of noise.

## Cost

Each unanswered identifier costs the adapter's full response timeout, so the
default sweep (256 identifiers × 2 passes) runs about two minutes. Plan the
state changes around that: the scan is the slow part, opening the gate is not.

## What it feeds

A confirmed identifier goes into `ProprietarySignal` with its real address,
replacing the invented one:

```swift
static let gate = ProprietarySignal(id: 0x0142, name: "Rear gate", isBoolean: true)
```

Everything downstream — the Vehicle tab, the gate chime policy, Sterope rules
that watch a `SignalRef` — is already written against that identifier and
starts working against the actual car the moment it's real. That was the point
of building the whole thing against a simulator first.

## Related

- `first-contact.md` — the session that produced the finding above
- `architecture.md` appendix A — verified standard PIDs on this car
- `chimes.md` — what we do with the gate signal once we have it
