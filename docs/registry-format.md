# The pleiades registry format

A community-maintained description of **what a car's modules will tell you,
and how anybody knows**.

There is no such dataset today. opendbc covers broadcast frames for ~100
platforms but names no modules, carries no diagnostic identifiers, and has no
way to say who measured what. ODX — the industry format that *does* describe
modules and identifiers — has no concept of evidence, because it's authored by
people who already know the answer. Manufacturers don't publish either.

So this format exists to hold the thing both of those drop: **the difference
between a measurement and an assertion.**

## The one idea

A contribution is not "this identifier is the tailgate." A contribution is
**"here is what I did, and here is what happened."** Confidence is *derived*
from those observations, never written down directly.

That inverts the usual thing. You can't mark something confirmed; you can only
record evidence good enough that it becomes confirmed. And because
observations carry who and when, two people on two different cars reaching the
same answer is expressible — which is a stronger claim than any one person can
make alone, and something no vehicle dataset currently records.

## Files

```
registry/
  subaru-global-2017.json      one file per platform
  honda-...json
```

One platform, not one car. Your Forester's body module is also a Crosstrek's.

## Identifying the car

Users should never pick their model from a dropdown. The set of module
addresses that answer `22 F197` is a **fingerprint** — plug in, scan, match,
load.

```json
"fingerprint": {
  "respondingModules": ["0x71F", "0x74A", "0x75A", "0x788", "0x7E8"],
  "minimumMatch": 0.8
}
```

Partial matching on purpose: trim levels differ, and a Forester without
blind-spot radar shouldn't fail to match a registry that lists it.

## Schema

```json
{
  "schema": "pleiades-registry/1",
  "platform": {
    "id": "subaru-global-2017",
    "name": "Subaru Global Platform",
    "models": ["Forester 2019-2024", "Crosstrek 2018-2023"],
    "protocol": { "elm327": 6, "description": "ISO 15765-4, CAN 11-bit, 500 kbit/s" },
    "fingerprint": { "respondingModules": ["0x75A"], "minimumMatch": 0.8 }
  },

  "contributors": [
    { "id": "briancorbin", "vehicles": ["2022 Forester Wilderness (FB25D)"] }
  ],

  "modules": [{
    "address": "0x75A",
    "name": "Integ. Unit",
    "nameSource": "uds-f197",
    "role": "Body integrated unit — doors, gate, lighting, chimes",
    "pages": ["01", "02", "10", "11", "F1", "FF"],
    "identifiersAnswering": 191,

    "signals": [{
      "did": "0x104E",
      "name": "Rear gate",
      "encoding": { "kind": "boolean", "trueValue": "FF", "falseValue": "00" },
      "access": { "read": true, "write": false, "securityAccess": null },
      "observations": [{
        "by": "briancorbin",
        "vehicle": "2022 Forester Wilderness",
        "date": "2026-07-30",
        "states": ["gate closed", "gate open", "psgr door open"],
        "changed": { "from": "00", "to": "FF" },
        "reverted": true,
        "discriminated": ["0x1073", "0x1117"],
        "evidence": "logs/did-20260730-191652.json",
        "method": "Enumerated 0x75A across three states. 104E moved for the gate and ignored the passenger door."
      }]
    }]
  }],

  "broadcastFrames": [...],
  "openQuestions": [...],
  "conventions": [...]
}
```

## Encoding

Declared per signal, because **it is not consistent within a car.** `0x75A`
answers its latches `00`/`FF`; `0x788` answers its buckles `01`/`02`. A
decoder that assumes "non-zero means true" reports every unfastened seatbelt
as fastened.

```json
{ "kind": "boolean", "trueValue": "FF", "falseValue": "00" }
{ "kind": "scaled",  "divisor": 10, "unit": "kPa", "bytes": 2 }
{ "kind": "enum",    "values": { "01": "Park", "02": "Reverse" } }
{ "kind": "raw" }
```

`raw` is the honest default for the 237 identifiers that answer with no known
meaning. They belong in the registry — "this exists and nobody knows what it
does" is a fact, and a work queue.

## Confidence is computed, never written

| Derived | When |
|---|---|
| `confirmed` | an observation with `reverted: true`, **or** two observations from different contributors agreeing |
| `candidate` | at least one observation, none reverted |
| `unidentified` | the identifier answers; no observation explains it |
| `rejected` | an observation explicitly marking it noise |

`reverted` is doing the heavy lifting. A byte that goes true when the gate
opens is a correlation. One that goes true and then false again when it shuts
is a measurement. `0x1024` survived three runs looking like the tailgate
before the volatile filter caught it drifting on its own — one revert check
would have killed it immediately.

`discriminated` records the identifiers that moved *together* and were ruled
out. Three moved when the tailgate opened; only opening the passenger door
instead told them apart. Without that field, the next person repeats the
elimination.

## Access, and why write is gated

```json
"access": { "read": true, "write": false, "securityAccess": null }
```

**`write: true` requires `confidence: confirmed`.** Enforced by test, not by
policy.

Reading a misidentified identifier costs nothing — you get a number you
misinterpret. Writing to one can misconfigure a restraint system, an
immobiliser, or something with no undo, on a car belonging to someone who
trusted this data. "I think this is a seatbelt" is not a good enough basis for
`2E`.

`securityAccess` records when a module demands `27` before it will accept a
write, so a tool can say "this needs a seed/key exchange" rather than failing
opaquely.

## Contributing

1. Run `pleiades map` — identifies modules, builds the fingerprint.
2. Run `pleiades procedure doors` (or the Discover tab) — scripted capture,
   which tags states correctly and checks the revert automatically.
3. Export. The observation carries your id, your vehicle, the states, the
   bytes, the evidence file.
4. Open a PR. Merging appends observations; it never overwrites someone
   else's.

Two contributors reaching the same answer on different cars is the strongest
signal this format can carry. It should be easy, and it should be visible.

## What this is not

**Not ODX.** ODX is generated *from* this, containing only `confirmed`
entries, for tools that speak it. Exporting a candidate as ODX would state a
guess in a machine-readable format, which is worse than stating it in prose.

**Not a substitute for measuring.** Every row says who checked and how, so a
reader can disagree with the method rather than take the conclusion on trust.
That's the whole point.
