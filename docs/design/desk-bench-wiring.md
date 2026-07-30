# Desk bench wiring

Two ESP32-S3 boards, two SN65HVD230 transceivers, one two-node CAN bus.
**11 wires total.**

## The whole picture

```
        ESP32-S3  (AMBER LED)                    ESP32-S3  (VIOLET LED)
             Electra                                    Merope
        ┌───────────────┐                          ┌───────────────┐
        │           3V3 ├──────┐            ┌──────┤ 3V3           │
        │           GND ├────┐ │            │ ┌────┤ GND           │
        │      GPIO 5/TX├──┐ │ │            │ │ ┌──┤ GPIO 5/TX     │
        │      GPIO 4/RX├┐ │ │ │            │ │ │┌─┤ GPIO 4/RX     │
        └───────────────┘│ │ │ │            │ │ ││ └───────────────┘
                         │ │ │ │            │ │ ││
                    ┌────┼─┼─┼─┼────┐  ┌────┼─┼─┼┼────┐
                    │    │ │ │ └3.3V│  │3.3V┘ │ ││    │
                    │    │ │ └──GND │  │ GND──┘ ││    │
                    │    │ └────CTX │  │ CTX────┘│    │
                    │    └──────CRX │  │ CRX─────┘    │
                    │               │  │              │
                    │   CANH   CANL │  │ CANH   CANL  │
                    └────┬───────┬──┘  └──┬───────┬───┘
                         │       │        │       │
                         └───────┼────────┘       │      ← CANH to CANH
                                 └────────────────┘      ← CANL to CANL

                    Waveshare #1            Waveshare #2

                 plus:  Electra GND ────────── Merope GND
```

## Per board — 4 wires, identical on both

| ESP32-S3 pin | → | Waveshare pin | Also labeled |
|---|---|---|---|
| `3V3` | → | `3.3V` | `VCC` |
| `GND` | → | `GND` | |
| `5` (TWAI TX) | → | `CTX` | `CAN_TX`, `D`, `TXD` |
| `4` (TWAI RX) | → | `CRX` | `CAN_RX`, `R`, `RXD` |

Nothing about this differs between the two boards — they're wired the same;
only the flashed firmware differs.

## Between the two transceivers — 3 wires

| Waveshare #1 | → | Waveshare #2 |
|---|---|---|
| `CANH` | → | `CANH` |
| `CANL` | → | `CANL` |
| `GND` | → | `GND` |

**Not crossed.** H to H, L to L. The GND link matters even though CAN is
differential — both nodes need a shared voltage reference.

Termination is already on both Waveshare boards (120 Ω each), which is
exactly the two-terminator topology a bus wants. Add nothing.

## Verify before debugging software

1. **Power at each transceiver.** Multimeter across its `3.3V` and `GND`
   pins: expect ~3.3 V. *This is the one measurement that matters* — an
   unpowered transceiver produced every failure we chased on this bench.
   Watch for `3V3` and `5V` being neighbors on the S3 header.
2. **Continuity `CANH`↔`CANH` and `CANL`↔`CANL`** between boards.
3. **Both LEDs lit** — amber and violet. A dark LED means that board isn't
   running its firmware (tap `RST`).

## Reading the failure

Each fault has a distinct signature in the logs, which is why the firmware
prints error counters rather than just "it didn't work":

| Symptom | Meaning | Look at |
|---|---|---|
| `BUS_OFF`, `tx_err` climbing, `rx_err 0` | transmitted bits never came back | transceiver power; GPIO5→CTX wire |
| `RUNNING`, `queued` stuck, no errors at all | RX pin reads permanently dominant — controller never sees an idle bus, so it never starts | transceiver power; GPIO4→CRX wire |
| `RECOVERING` forever | bus held dominant; recovery needs an idle bus it never gets | a transceiver driving the bus low |
| `0 frames AND rx_err 0` on the receiver | controller sees a genuinely idle bus | that board's power and GPIO4→CRX wire — signal isn't arriving at all |
| `rx_err` climbing on the receiver | signal *is* arriving but malformed | crossed CANH/CANL, bitrate mismatch |

The distinction in the last two rows is the important one: on a listen-only
node, a quiet bus and a broken ear look identical unless you check whether
errors are accumulating.

## Boards are color-coded

Two identical dev boards are indistinguishable, so each firmware claims the
onboard RGB LED (GPIO48):

- 🟠 **amber** — Electra, the fake car (red if its bus goes unhealthy)
- 🟣 **violet** — Merope, the black box (dim = quiet bus, bright = frames
  flowing, red = capturing a fault window)

Colors match their Linear labels.
