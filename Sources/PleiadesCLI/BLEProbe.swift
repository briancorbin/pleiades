#if canImport(CoreBluetooth)
import Foundation
import Maia

/// First-contact tool for a BLE dongle. Narrates every step so a failure
/// says *where* it failed, then dumps the car's real supported-PID map —
/// which is the actual deliverable of phase 1.
/// Scan callbacks arrive on the transport's queue; dedupe safely.
private final class SeenNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func insert(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.insert(name).inserted
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.isEmpty
    }
}

/// macOS kills a process that touches CoreBluetooth without permission, and
/// it does it silently — no state callback, no crash message.
private func printPermissionHelp() {
    print("""

    Bluetooth never reported a state. On macOS that means TCC denied access
    (the process gets killed the moment it creates a CBCentralManager).

    scripts/ble-probe.sh already embeds an Info.plist with a usage string,
    so what's left is granting the terminal itself:

      System Settings → Privacy & Security → Bluetooth
        → enable your terminal app, then re-run this script.

    If it still won't budge, use the iPad instead — Alcyone-iOS gets a
    normal permission prompt. Source badge → "OBD dongle · BLE".
    """)
}

enum BLEProbe {
    static func run(nameHint: String?, scanOnly: Bool) async throws {
        let transport = BLEELMTransport(nameHint: nameHint)

        transport.onStateChange = { state in
            print("  [ble] \(state.describedState)")
        }

        if scanOnly {
            let seen = SeenNames()
            transport.onDiscover = { name, rssi in
                guard seen.insert(name) else { return }
                print(String(format: "  %-28s  %4d dBm", (name as NSString).utf8String!, rssi))
            }
            print("Scanning for BLE devices (10s). Look for the dongle's name:\n")
            transport.connect()
            try await Task.sleep(for: .seconds(10))
            transport.disconnect()
            if case .idle = transport.state {
                printPermissionHelp()
            } else if seen.isEmpty {
                print("\nNo devices seen. Is Bluetooth on, and is the dongle powered")
                print("(plugged into the OBD port with the ignition at least in ACC)?")
            } else {
                print("\nRe-run with:  pleiades ble --name <substring>")
            }
            return
        }

        print("Connecting…")
        transport.connect()
        try await transport.waitUntilReady()

        print("\nInitializing adapter…")
        let session = ELM327Session(transport: transport)
        try await session.initialize()

        // Adapter identity — this is the one command that answers even with
        // the ignition off, so it separates "no dongle" from "no car".
        if let version = try? await transport.send("ATI") {
            print("  adapter: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        print("\nWalking supported PIDs…")
        let supported: Set<UInt8>
        do {
            supported = try await session.supportedPIDs()
        } catch {
            print("  ✗ \(error)")
            print("\n  If this says NO DATA or UNABLE TO CONNECT, the adapter is fine")
            print("  but the ECU isn't answering — turn the ignition on (engine")
            print("  running is best) and try again.")
            transport.disconnect()
            return
        }

        let inCatalog = PID.all.filter { supported.contains($0.code) }
        let unknown = supported.subtracting(PID.all.map(\.code)).sorted()

        print("  ECU answers \(supported.count) standard PIDs\n")
        print("In Maia's catalog (\(inCatalog.count)):")
        for pid in inCatalog {
            print(String(format: "  %@  %-28s %@", pid.command, (pid.name as NSString).utf8String!, pid.unit))
        }

        // The two we flagged as uncertain for the FB25 back in phase 0.
        print("\nOpen questions from the design doc:")
        for pid in [PID.oilTemp, PID.fuelRate] {
            print("  \(pid.command) \(pid.name): \(supported.contains(pid.code) ? "✓ supported" : "✗ not supported")")
        }

        if !unknown.isEmpty {
            print("\nSupported but not in our catalog (\(unknown.count)):")
            print("  " + unknown.map { String(format: "%02X", $0) }.joined(separator: " "))
        }

        print("\nLive sample:")
        for pid in inCatalog.prefix(8) {
            if let reading = try? await session.read(pid) {
                print(String(format: "  %-28s %8.1f %@", (pid.name as NSString).utf8String!, reading.value, pid.unit))
            } else {
                print(String(format: "  %-28s       -- (no data)", (pid.name as NSString).utf8String!))
            }
        }

        print("\nPaste this whole output back into the session — it settles")
        print("appendix A in docs/design/architecture.md.")
        transport.disconnect()
    }
}
#endif
