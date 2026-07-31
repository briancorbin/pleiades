import Foundation
import Electra
import Maia

/// Bench and first-contact tool.
///
///     pleiades demo [seconds]      # drive the Electra fake car (default 30s)
///     pleiades ble [--name X]      # probe a BLE dongle: connect, PID map, sample
///     pleiades ble --scan          # just list nearby BLE devices
///     pleiades bench [host[:port]] # poll a WiFi dongle (default 192.168.0.10:35000)
///     pleiades scan [--tag X]      # sweep mode-22 identifiers, diff vs last sweep
///     pleiades compare a.json b.json  # diff two stored sweeps, no car needed
@main
struct Pleiades {
    static let watchlist: [PID] = [
        .rpm, .speed, .coolantTemp, .engineLoad, .throttle, .controlModuleVoltage,
    ]

    static func main() async {
        // Unbuffered: this tool narrates long-running work, and block
        // buffering would hide everything until exit (or forever, if the
        // user ctrl-Cs a scan that appeared to be doing nothing).
        setvbuf(stdout, nil, _IONBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first ?? "demo" {
            case "demo":
                try await demo(seconds: args.dropFirst().first.flatMap { Int($0) } ?? 30)
            case "bench":
                try await bench(endpoint: args.dropFirst().first ?? "192.168.0.10:35000")
            case "ble":
                #if canImport(CoreBluetooth)
                let rest = Array(args.dropFirst())
                try await BLEProbe.run(
                    nameHint: value(of: "--name", in: rest),
                    scanOnly: rest.contains("--scan")
                )
                #else
                print("BLE requires CoreBluetooth (macOS/iOS).")
                exit(2)
                #endif
            case "scan":
                #if canImport(CoreBluetooth)
                let rest = Array(args.dropFirst())
                try await DIDScanner.run(
                    nameHint: value(of: "--name", in: rest),
                    // 0x01xx is the range the car was seen answering during
                    // recon. Sweeping all 65,536 identifiers would take a day.
                    first: hex(value(of: "--from", in: rest)) ?? 0x0100,
                    last: hex(value(of: "--to", in: rest)) ?? 0x01FF,
                    passes: value(of: "--passes", in: rest).flatMap { Int($0) } ?? 2,
                    tag: value(of: "--tag", in: rest),
                    compareTo: value(of: "--compare", in: rest),
                    includeVolatile: rest.contains("--include-volatile"),
                    // ELM327 response timeout, in units of 4 ms. 0x32 is 200 ms,
                    // which is enough for a dozen modules to get a word in.
                    st: value(of: "--st", in: rest) ?? "32",
                    extendedSession: rest.contains("--extended"),
                    force: rest.contains("--force"),
                    module: value(of: "--module", in: rest).flatMap { UInt32($0, radix: 16) }
                )
                #else
                print("Scanning requires CoreBluetooth (macOS/iOS).")
                exit(2)
                #endif
            case "enum":
                #if canImport(CoreBluetooth)
                let rest = Array(args.dropFirst())
                guard let module = value(of: "--module", in: rest).flatMap({ UInt32($0, radix: 16) }) else {
                    print("usage: pleiades enum --module 75A [--pages 01,02,10,11] [--tag X]")
                    exit(2)
                }
                let pages = value(of: "--pages", in: rest)
                    .map { $0.split(separator: ",").compactMap { UInt8($0, radix: 16) } }
                    ?? [0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x20, 0x30]
                try await DIDEnumerator.run(
                    nameHint: value(of: "--name", in: rest),
                    module: module,
                    pages: pages,
                    tag: value(of: "--tag", in: rest),
                    passes: value(of: "--passes", in: rest).flatMap { Int($0) } ?? 2,
                    st: value(of: "--st", in: rest) ?? "32",
                    compareTo: value(of: "--compare", in: rest),
                    includeVolatile: rest.contains("--include-volatile"),
                    extendedSession: rest.contains("--extended")
                )
                #else
                print("Enumeration requires CoreBluetooth (macOS/iOS).")
                exit(2)
                #endif
            case "map":
                #if canImport(CoreBluetooth)
                let rest = Array(args.dropFirst())
                try await DIDMapper.run(
                    nameHint: value(of: "--name", in: rest),
                    st: value(of: "--st", in: rest) ?? "32",
                    module: value(of: "--module", in: rest).flatMap { UInt32($0, radix: 16) },
                    extendedSession: rest.contains("--extended")
                )
                #else
                print("Mapping requires CoreBluetooth (macOS/iOS).")
                exit(2)
                #endif
            case "compare":
                let rest = Array(args.dropFirst())
                let files = rest.filter { !$0.hasPrefix("--") }
                guard files.count == 2 else {
                    print("usage: pleiades compare <before.json> <after.json> [--include-volatile]")
                    exit(2)
                }
                let before = try DIDReport.load(files[0])
                let after = try DIDReport.load(files[1])
                DIDReport.printSummary(after)
                DIDReport.printDiff(
                    from: before,
                    to: after,
                    includeVolatile: rest.contains("--include-volatile")
                )
            default:
                print("""
                usage:
                  pleiades demo [seconds]       drive the Electra fake car
                  pleiades ble [--name X]       probe a BLE dongle
                  pleiades ble --scan           list nearby BLE devices
                  pleiades bench [host[:port]]  poll a WiFi dongle
                  pleiades scan [options]       sweep mode-22 identifiers
                      --tag "gate closed"       label the vehicle state (do this)
                      --from 0100 --to 01FF     identifier range
                      --passes 2                repeats, to flag volatile values
                      --compare <file.json>     diff target (default: last sweep)
                      --include-volatile        show values that move on their own
                      --st 32                   adapter response timeout, ×4ms
                      --extended                enter diagnostic session 10 03
                      --force                   sweep even if preflight is bleak
                      --module 78E              listen to one module only
                  pleiades enum --module 75A   read everything one module has,
                      --pages 01,02,10,11       by walking its support bitmasks
                      --tag "gate closed"       instead of sweeping blind
                  pleiades map [options]        find where the data lives:
                                                identify modules, probe every
                                                page marker 22 XX00
                  pleiades compare <a> <b>      diff two stored sweeps, no car
                """)
                exit(2)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    /// `--flag value`, tolerating a flag that trails off the end of argv.
    static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: index)
        guard next < args.endIndex, !args[next].hasPrefix("--") else { return nil }
        return args[next]
    }

    static func hex(_ text: String?) -> UInt16? {
        guard let text else { return nil }
        return UInt16(text.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    static func demo(seconds: Int) async throws {
        let car = ElectraCar()
        let session = ELM327Session(transport: ELM327Emulator(car: car))
        try await session.initialize()
        try await report(session)

        await car.startEngine()
        print("Engine start. Cold idle, then a pull, then cruise:\n")
        for tick in 0..<seconds {
            // Little scripted drive: idle → 60% throttle pull → light cruise.
            switch tick {
            case 5: await car.setThrottle(60)
            case 15: await car.setThrottle(15)
            default: break
            }
            await car.advance(by: 1)
            try await printDashboardLine(session)
            try await Task.sleep(for: .seconds(1))
        }
    }

    static func bench(endpoint: String) async throws {
        let parts = endpoint.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 35000 : 35000

        print("Connecting to \(host):\(port)…")
        let transport = ELMTCPTransport(host: host, port: port)
        try await transport.connect()
        let session = ELM327Session(transport: transport)
        try await session.initialize()
        print("Adapter initialized.")
        try await report(session)

        while true {
            try await printDashboardLine(session)
            try await Task.sleep(for: .seconds(1))
        }
    }

    static func report(_ session: ELM327Session) async throws {
        let supported = try await session.supportedPIDs()
        let catalog = PID.all.filter { supported.contains($0.code) }
        print("ECU answers \(catalog.count)/\(PID.all.count) catalog PIDs:")
        for pid in catalog {
            print("  \(pid.command)  \(pid.name) (\(pid.unit))")
        }
        print("")
    }

    static func printDashboardLine(_ session: ELM327Session) async throws {
        var parts: [String] = []
        for pid in watchlist {
            do {
                let reading = try await session.read(pid)
                parts.append("\(pid.name) \(String(format: "%.0f", reading.value)) \(pid.unit)")
            } catch {
                parts.append("\(pid.name) --")
            }
        }
        print(parts.joined(separator: "  |  "))
    }
}
