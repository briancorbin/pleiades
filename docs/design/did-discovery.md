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

## The trap: the adapter is deaf to most of the car

The first sweep of `0x0100–0x01FF` came back with answers from exactly one
module — the ECM at `0x7E8`, mostly `FF` placeholders. Nothing moved when the
gate opened, because the gate was never asked.

**In protocol 6 an ELM327's CAN receive filter accepts only `0x7E8–0x7EF`**,
the response window the emissions standard reserves. Every module that knows
about latches lives outside it. They answer; the dongle discards the answers
in hardware before any software sees them.

We know they answer because Merope watched them do it. From the recon log,
one functional request and fifteen replies:

```
0x7DF   03 22 01 01 ...            the request going out
0x7E8   04 62 01 01 FF             the ECM  — the only one the dongle showed
0x74A   07 62 01 00 00 00 E0 50    a body module answering the same request
0x78E   07 62 01 00 FF C1 FF F1    another, with different data
```

Merope has no filter, which is precisely why it saw all fourteen.

So the scanner widens the filter before sweeping — `ATCF 700` plus `ATCM 700`
makes only the top three address bits significant, admitting `0x700–0x7FF` —
and then **proves it worked** with a single-identifier preflight before
spending two minutes on the full range. If fewer than three modules answer
`22 0100`, it stops and says so rather than sweeping a car it can't hear.

Not every clone implements those commands. One that answers `?` can't be
widened, and the sweep has to run through Merope instead.

It also pins fixed timing (`ATAT0` with an explicit `ATST`). Adaptive timing
tunes the wait from observed response times, which is right when one ECU
answers and wrong here — it returns as soon as the fastest module replies and
truncates the dozen behind it.

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

### Found it — 2026-07-30

Module `0x75A`, enumerated three times:

| DID | gate closed | gate open | psgr door open | |
|---|---|---|---|---|
| `104B` | `00` | `00` | `FF` | front passenger door |
| `104E` | `00` | **`FF`** | `00` | **the rear gate** |
| `1073` | `00` | `FF` | `FF` | any opening |
| `1116` | `00` | `00` | `FF` | passenger door, page 11 mirror |
| `1117` | `00` | `FF` | `00` | rear gate, page 11 mirror |

**`22 104E` on `0x75A` is the rear gate.** `FF` open, `00` shut.

The third state is what earned it. The first diff turned up three
identifiers moving together, and any of them could have been the gate.
Opening the passenger door instead split them cleanly: `104E` ignored it,
`104B` tracked it, `1073` responded to both — so `1073` is an aggregate and
the other two are specific.

Two details worth carrying:

- **The car answers `FF` for true, not `01`.** A decoder testing `== 1`
  reads every open tailgate as closed.
- **`1024` was a false positive.** It moved `A6 → A5` in the first diff and
  looked like a candidate; across three runs the two-pass filter caught it
  drifting on its own and excluded it. That mechanism paid for itself here.

Still unmeasured: the other three doors (`104A`, `104C`, `104D` are the
neighbours, all `00` throughout, almost certainly them but not yet proven one
at a time), seatbelts (try module `0x788`, Airbag System), and TPMS (try
`0x75B`, Tire pressure monitor).

## Confirm before believing

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

## What page 01 turned out to be — and the shortcut it handed us

The first complete sweep, with the filter open, got 156 answers from all
fifteen modules. Nothing changed when the tailgate opened. Nothing was even
*volatile* — 156 identifiers, two passes, on a live car, and not one byte
drifted.

That's not a null result. It says page 01 isn't live data at all, and reading
it properly says what it is instead:

**`22 xx00` is a support bitmask.** Four bytes, one bit per identifier,
covering the 32 that follow — with the last bit chaining to the next block.
The exact convention mode-01 PID `00` uses, which this codebase already walks
in `supportedPIDs()`.

The car told us so unambiguously. `74A` answered `00 00 E0 50` at `0x0100`,
which decodes to `0111 0112 0113 011A 011C` — precisely the five identifiers
it went on to answer, and no others. `78F` and `7DD` were the only two modules
with the chain bit set at `0x0120`, and the only two that answered `0x0140`.

So page 01 is a dozen constant status flags per module — `01` for present,
`FF` for not-applicable — and it is now **fully enumerated**. The gate is not
in it, and we never have to look again.

The shortcut is the point. A 65,536-identifier space does not need 65,536
requests: ask the 256 page markers and the car says where its data lives.

```bash
./scripts/did-map.sh
```

That also reads the standard UDS identity identifiers (`F190` VIN, `F197`
system name, `F187` part number) from every module, which turns `0x78E` from
an address into a name — worth knowing when fifteen modules answer and only
one of them owns the tailgate.

## A caveat the masks exposed: functional addressing loses responses

Nine of the fifteen modules answered exactly what their bitmask advertised.
The other six advertised identifiers they never answered — and they were the
six with the fewest replies overall (`71F`, `75B`, `788`, `7B8` at two each).

They aren't inconsistent. Their answers were lost. Fifteen modules replying to
one functional request is real contention, and the adapter drops what it can't
keep up with.

Use `--module 78E` to narrow the receive filter to one module when a result
has to be complete rather than fast. It costs a sweep per module and removes
the loss entirely.

## The module map — 2026-07-30

Every module carries the standard UDS identifier `F197`, and it answers in
plain ASCII. Fifteen addresses became fifteen named boxes for the cost of one
request each:

| Address | `F197` says | Why we care |
|---|---|---|
| `75A` | **Integ. Unit mode** | the body integrated unit — doors, gate, lighting, chimes |
| `7BC` | Keyless Access & Push Start (C) | knows door and gate state for entry |
| `7C9` | Keyless Access & Push Start (P) | the passenger-side half |
| `788` | Airbag System | seatbelt buckle switches |
| `75B` | Tire pressure monitor | TPMS, per wheel |
| `71F` | Electric Brake Booster | |
| `74A` / `74B` | RADAR ASSY B&S LH / RH | blind-spot radar |
| `77E` | Data Communication Module | telematics |
| `78E` | Sonar system | parking sensors |
| `78F` | EyeSight | 92 pages — by far the richest module |
| `7B8` | VDC/Parking Brake System | |
| `7DD` | MFD | the centre display |
| `7E8` | 2.5 DOHC | the engine; also holds the VIN at `F190` |
| `78B` | *(wouldn't say)* | answers pages `02 03 10 A0` |

The VIN came back clean from `7E8`: `JF2SKAMCXNH519189`.

Pages `01 02 10 F1 FF` are near-universal boilerplate. The *distinctive*
pages are where a module keeps its own business — `75A` has `11`, `788` has
`23`, the Keyless pair have `11 12 13 20 30`, EyeSight has ninety-two.

## Enumerate, don't sweep

Once the bitmask convention is known, sweeping a range is the wrong tool.
Ask `22 XX00`, decode what it advertises, follow the chain bit, read only what
exists:

```bash
./scripts/did-enum.sh --module 75A --tag "gate closed"
```

A page costs eight mask reads plus however many identifiers are really there,
instead of 256 requests that are mostly `requestOutOfRange`. It also narrows
the receive filter to one module, so nothing is lost to contention. The output
is an ordinary snapshot, so `compare` diffs an enumeration exactly like a
sweep.

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
