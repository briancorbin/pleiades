#if canImport(CoreBluetooth)
import Foundation
import Maia

/// Reads everything one module admits to having, by walking its own support
/// bitmasks instead of sweeping ranges blind.
///
/// The map turned fifteen addresses into fifteen named modules, and the
/// support-bitmask convention means none of them need brute-forcing. Ask
/// `22 XX00`, decode the four bytes into the identifiers it advertises,
/// follow the chain bit to the next block, and read only what's there. A page
/// costs eight mask reads plus however many identifiers actually exist,
/// instead of 256 requests that are mostly `requestOutOfRange`.
///
/// The result is an ordinary `DIDSnapshot`, so `pleiades compare` diffs an
/// enumeration exactly like it diffs a sweep.
enum DIDEnumerator {
    /// Named from the car's own `F197` replies, so the tool can talk about
    /// "Integ. Unit" rather than 75A.
    static let known: [UInt32: String] = [
        0x71F: "Electric Brake Booster",
        0x74A: "RADAR ASSY B&S LH",
        0x74B: "RADAR ASSY B&S RH",
        0x75A: "Integ. Unit",
        0x75B: "Tire pressure monitor",
        0x77E: "Data Communication Module",
        0x788: "Airbag System",
        0x78B: "(unnamed)",
        0x78E: "Sonar system",
        0x78F: "EyeSight",
        0x7B8: "VDC/Parking Brake System",
        0x7BC: "Keyless Access & Push Start (C)",
        0x7C9: "Keyless Access & Push Start (P)",
        0x7DD: "MFD",
        0x7E8: "2.5 DOHC (engine)",
    ]

    static func name(_ module: UInt32) -> String {
        known[module] ?? "unknown"
    }

    /// The pages each module said it has, from `pleiades map`, via the
    /// registry.
    ///
    /// Sweeping a generic page list is how page `23` on the airbag module got
    /// missed — the default set didn't include it, and `23` is exactly the
    /// page that module keeps its own business on. Ask each module about the
    /// pages *it* advertises instead of guessing, and the coverage question
    /// stops being a guess too.
    static func advertisedPages(for module: UInt32) -> [UInt8]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Registry.jsonPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modules = root["modules"] as? [[String: Any]]
        else { return nil }

        let wanted = String(format: "0x%03X", module)
        guard let entry = modules.first(where: { ($0["address"] as? String)?.uppercased() == wanted }),
              let pages = entry["pages"] as? [String]
        else { return nil }

        // Ranges like "10-16" expand; plain entries pass through.
        return pages.flatMap { page -> [UInt8] in
            let parts = page.split(separator: "-")
            guard let first = UInt8(parts[0], radix: 16) else { return [] }
            guard parts.count == 2, let last = UInt8(parts[1], radix: 16), last >= first else {
                return [first]
            }
            return Array(first...last)
        }
    }

    static func run(
        nameHint: String?,
        module: UInt32,
        pages: [UInt8],
        tag: String?,
        passes: Int,
        st: String,
        compareTo: String?,
        includeVolatile: Bool,
        extendedSession: Bool
    ) async throws {
        print("""
        Enumerating \(String(format: "%03X", module)) — \(name(module))
        Pages: \(pages.map { String(format: "%02X", $0) }.joined(separator: " "))
        \(tag.map { "State: \($0)" } ?? "No --tag given; the diff will be harder to read later.")
        """)

        let transport = BLEELMTransport(nameHint: nameHint)
        transport.onStateChange = { print("  [ble] \($0.describedState)") }
        print("\nConnecting…")
        transport.connect()
        try await transport.waitUntilReady()

        let session = ELM327Session(transport: transport)
        try await session.initialize(pinnedProtocol: 6)
        try await DIDScanner.configure(session, st: st, extendedSession: extendedSession)

        // One module at a time. Fifteen answering the same functional request
        // costs responses — six of them advertised identifiers they never got
        // a word in edgewise about.
        _ = try? await session.send(String(format: "ATCRA%03X", module))
        print("  listening only to \(String(format: "%03X", module))")

        var collected: [[DIDReply]] = []
        for pass in 1...passes {
            print("\nPass \(pass) of \(passes):")
            var replies: [DIDReply] = []
            for page in pages {
                replies += try await walk(session, module: module, page: page)
            }
            collected.append(replies)
        }
        transport.disconnect()

        let identifiers = collected.flatMap { $0 }.map(\.did)
        let snapshot = DIDSnapshot.merge(
            passes: collected,
            tag: tag,
            firstDID: identifiers.min() ?? 0,
            lastDID: identifiers.max() ?? 0,
            capturedAt: Date()
        )
        DIDReport.printSummary(snapshot)

        let path = try DIDReport.write(snapshot)
        print("\nSaved \(path)")

        let previous = compareTo ?? DIDReport.mostRecent(excluding: path)
        guard let previous else {
            print("""

            First enumeration stored. Change one thing — open the gate — and
            run the same command again.
            """)
            return
        }
        do {
            let before = try DIDReport.load(previous)
            print("\nComparing against \(previous)")
            DIDReport.printDiff(from: before, to: snapshot, includeVolatile: includeVolatile)
        } catch {
            print("\nCouldn't read \(previous) to compare: \(error)")
        }
    }

    /// Walk one page's bitmask chain, then read what it advertised.
    private static func walk(_ session: ELM327Session, module: UInt32, page: UInt8) async throws -> [DIDReply] {
        var out: [DIDReply] = []
        var advertised: [UInt16] = []
        var base = UInt16(page) << 8

        // Blocks step by 0x20, each mask covering the 32 identifiers after it,
        // the last bit chaining onward — the same shape as the PID walk.
        for _ in 0..<8 {
            guard let mask = (try? await session.scanDID(base))?.first(where: \.isPositive),
                  let bytes = mask.data
            else { break }
            out.append(mask)
            advertised += DIDScan.supportedIdentifiers(mask: bytes, base: base)
            guard DIDScan.chainsToNextBlock(mask: bytes) else { break }
            let next = base &+ 0x20
            guard next > base else { break }
            base = next
        }

        // The block markers advertise themselves as the chain link; don't
        // re-read them as data.
        let targets = advertised.filter { $0 & 0x1F != 0 }
        var answered = 0
        for did in targets {
            guard let replies = try? await session.scanDID(did) else { continue }
            out += replies
            answered += replies.filter(\.isPositive).count
        }

        print(String(
            format: "  page %02X   %3d advertised, %3d answered",
            page, targets.count, answered
        ))
        return out
    }
}
#endif
