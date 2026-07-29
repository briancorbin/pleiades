# pleiades ✦

Personal vehicle-telemetry platform for a 2022 Subaru Forester Wilderness:
tap the OBD-II/CAN data, turn it into one typed reading stream, and render it
however I want on an iPad.

*Subaru* is the Japanese name for the Pleiades star cluster — the logo is the
six stars. So the platform is the cluster and the components are the sisters:

| Star | Component | Status |
|---|---|---|
| **Maia** | Core library — ELM327 protocol, PID catalog, decoding, transports | phase 0 ✅ |
| **Electra** | Bench simulator — a fake car behind a fake ELM327 | phase 0 ✅ |
| **Alcyone** | The iPad app (SwiftUI gauges) | phase 2 🚧 — dashboard runs on macOS against Electra |
| **Celaeno** | Fault-event archive — history that survives code clearing | born early 🌑 |
| **Merope** | Hardwired CAN tap (ESP32) for Subaru's proprietary frames | brain before body 🧠 — black-box core (ring buffer + fault watcher) host-tested in [firmware/merope](firmware/merope) |
| **Sterope** | Alert/threshold engine | born early ⚡ — hysteresis rules + alert banners live on the bench |

Full design: [docs/design/architecture.md](docs/design/architecture.md)

## Quickstart

```sh
swift test              # everything is testable with zero hardware
swift run pleiades demo # watch the fake Forester cold-start and take a pull
swift run alcyone       # the gauge dashboard in a window, driving Electra —
                        # start the engine, drag the throttle
```

On the iPad (drives Electra until the dongle arrives):

```sh
brew install xcodegen   # once
cd Alcyone-iOS && xcodegen generate && open Alcyone.xcodeproj
# set your signing team once, then run to the iPad
```

With a WiFi ELM327 dongle plugged into the real car:

```sh
swift run pleiades bench            # 192.168.0.10:35000
swift run pleiades bench host:port
```

## The one design rule

Transports are swappable and protocol frontends converge: BLE dongle, WiFi
dongle, ESP32 tap, and the Electra emulator all feed the same
`ELM327Session → OBDReading` pipeline, so nothing upstream ever knows where a
number came from.

## Why Electra exists

Most OBD-II libraries assume you're sitting in the driver's seat with a
dongle plugged in. This one ships a fake car: `ElectraCar` models plausible
vehicle behavior, `ELM327Emulator` wraps it in the real adapter dialect, and
Maia's actual `ELM327Session` drives it **unmodified**. Gauges, alert rules,
diagnostics, and fault-window capture were all built and tested against it
before the project ever touched a vehicle.

```sh
./scripts/bench.sh   # Swift + C suites, zero hardware
```

## Credits

Trouble-code descriptions in `Sources/Maia/Resources/dtc-codes.json` are
derived from [Wal33D/dtc-database](https://github.com/Wal33D/dtc-database)
(MIT) — see that file's `ATTRIBUTION.md`.

## License

MIT — see [LICENSE](LICENSE).
