#if canImport(CoreBluetooth)
import Foundation
import Maia

/// Maps the identifier space instead of brute-forcing it.
///
/// The first full sweep of `0x0100–0x01FF` paid for itself by revealing the
/// rule the car plays by: **`22 xx00` is a support bitmask**, four bytes
/// covering the next 32 identifiers, with the last bit chaining to the next
/// block. Exactly the convention mode-01 PID `00` uses, which the codebase
/// already walks in `supportedPIDs()`.
///
/// `74A` answering `00 00 E0 50` predicts 0111 0112 0113 011A 011C, and those
/// are precisely the five it answered. `78F` and `7DD` are the only modules
/// with the chain bit set and the only two that answered `0140`.
///
/// So the 65,536-identifier space doesn't need 65,536 requests. Ask each page
/// marker — 256 of them — and the car says where its data lives. What took
/// two minutes to learn about one page takes about one minute to learn about
/// all of them.
enum DIDMapper {
    /// Standardised identifiers every UDS module is supposed to carry. These
    /// turn `0x78E` from an address into a name, which matters once you have
    /// fifteen of them and need to know which one owns the tailgate.
    static let identity: [(id: UInt16, name: String)] = [
        (0xF197, "system name"),
        (0xF187, "spare part no"),
        (0xF188, "software no"),
        (0xF18C, "serial no"),
        (0xF191, "hardware no"),
        (0xF194, "software version"),
        (0xF18A, "supplier"),
        (0xF190, "VIN"),
    ]

    static func run(nameHint: String?, st: String, module: UInt32?, extendedSession: Bool) async throws {
        let transport = BLEELMTransport(nameHint: nameHint)
        transport.onStateChange = { print("  [ble] \($0.describedState)") }

        print("Connecting…")
        transport.connect()
        try await transport.waitUntilReady()

        let session = ELM327Session(transport: transport)
        try await session.initialize(pinnedProtocol: 6)
        try await DIDScanner.configure(session, st: st, extendedSession: extendedSession)
        if let module {
            // Listening to one module at a time removes the contention that
            // silently costs responses when fifteen answer at once.
            _ = try? await session.send(String(format: "ATCRA%03X", module))
            print("  listening only to \(String(format: "%03X", module))")
        }

        print("\nIdentity — standard UDS identifiers:")
        var identities: [String: String] = [:]
        for entry in identity {
            let replies = (try? await session.scanDID(entry.id)) ?? []
            for reply in replies.filter(\.isPositive) {
                guard let data = reply.data, !data.isEmpty else { continue }
                identities[String(format: "%03X:%@", reply.module, entry.name)] = render(data)
                print(String(
                    format: "  %03X  %-16s %@",
                    reply.module,
                    (entry.name as NSString).utf8String!,
                    render(data)
                ))
            }
        }
        if identities.isEmpty {
            print("  (nothing answered — this car may not carry the standard F1xx set)")
        }

        // Two passes, unioned. A page missed to contention in one pass is a
        // whole block of identifiers we'd never look at again.
        print("\nProbing page markers 22 0000 … 22 FF00 (2 passes):")
        var pages: [UInt32: Set<UInt8>] = [:]
        var masks: [String: [UInt8]] = [:]
        for pass in 1...2 {
            var found = 0
            for high in UInt8(0)...UInt8(255) {
                let did = UInt16(high) << 8
                guard let replies = try? await session.scanDID(did) else { continue }
                for reply in replies.filter(\.isPositive) {
                    guard let data = reply.data, data.contains(where: { $0 != 0 }) else { continue }
                    pages[reply.module, default: []].insert(high)
                    masks[String(format: "%03X:%02X", reply.module, high)] = data
                    found += 1
                }
                if high % 32 == 31 {
                    print(String(format: "  pass %d  %02X00–%02X00  %d answers", pass, high &- 31, high, found))
                    found = 0
                }
            }
        }

        transport.disconnect()
        report(pages: pages, masks: masks)

        // Persist it. A discovery tool whose findings live only in terminal
        // scrollback makes you re-run the car to answer a question about a
        // scan you already did.
        do {
            print("\nSaved \(try save(pages: pages, masks: masks, identities: identities))")
        } catch {
            print("\nCouldn't save the map: \(error)")
        }
    }

    private static func save(
        pages: [UInt32: Set<UInt8>],
        masks: [String: [UInt8]],
        identities: [String: String]
    ) throws -> String {
        try FileManager.default.createDirectory(atPath: DIDReport.directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let path = "\(DIDReport.directory)/map-\(stamp.string(from: Date())).json"

        var modules: [String: [String: Any]] = [:]
        for (module, highBytes) in pages {
            let key = String(format: "%03X", module)
            var entry: [String: Any] = [
                "pages": highBytes.sorted().map { String(format: "%02X", $0) },
            ]
            var blocks: [String: String] = [:]
            for high in highBytes.sorted() {
                if let mask = masks[String(format: "%03X:%02X", module, high)] {
                    blocks[String(format: "%02X00", high)] = mask.hexString
                }
            }
            entry["masks"] = blocks
            modules[key] = entry
        }
        for (key, value) in identities {
            let parts = key.split(separator: ":")
            guard parts.count == 2 else { continue }
            var entry = modules[String(parts[0])] ?? [:]
            var known = entry["identity"] as? [String: String] ?? [:]
            known[String(parts[1])] = value
            entry["identity"] = known
            modules[String(parts[0])] = entry
        }

        let payload: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "modules": modules,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static func report(pages: [UInt32: Set<UInt8>], masks: [String: [UInt8]]) {
        guard !pages.isEmpty else {
            print("""

            No page markers answered.

            That doesn't mean the space is empty — it means this car doesn't
            use the xx00 convention outside page 01, and the identifiers have
            to be found by sweeping ranges directly.
            """)
            return
        }

        print("\nPages that answered, by module:\n")
        for module in pages.keys.sorted() {
            let list = pages[module]!.sorted().map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "  %03X   %@", module, list))
        }

        print("""

        A page marker means a block of identifiers lives behind it. Sweep the
        promising ones and diff across a state change:

            ./scripts/did-scan.sh --from XX00 --to XXFF --tag "gate closed"

        Page 01 is already mapped — a dozen constant status flags per module,
        none of which track the gate. Anything new here is new ground.
        """)
    }

    /// Identity identifiers are usually ASCII; status words never are.
    static func render(_ data: [UInt8]) -> String {
        let printable = data.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard printable, data.count > 2 else { return data.hexString }
        return "\"\(String(decoding: data, as: UTF8.self))\"  (\(data.hexString))"
    }
}
#endif
