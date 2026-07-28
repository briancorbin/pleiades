import Foundation
import Electra
import Maia

/// Phase-0 bench tool.
///
///     pleiades demo [seconds]      # drive the Electra fake car (default 30s)
///     pleiades bench [host[:port]] # poll a real WiFi dongle (default 192.168.0.10:35000)
@main
struct Pleiades {
    static let watchlist: [PID] = [
        .rpm, .speed, .coolantTemp, .engineLoad, .throttle, .controlModuleVoltage,
    ]

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first ?? "demo" {
            case "demo":
                try await demo(seconds: args.dropFirst().first.flatMap { Int($0) } ?? 30)
            case "bench":
                try await bench(endpoint: args.dropFirst().first ?? "192.168.0.10:35000")
            default:
                print("usage: pleiades demo [seconds] | pleiades bench [host[:port]]")
                exit(2)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
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
