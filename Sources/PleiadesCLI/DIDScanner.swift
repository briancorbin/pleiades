#if canImport(CoreBluetooth)
import Foundation
import Maia

/// Sweeps a range of mode-22 identifiers through a BLE dongle and stores the
/// result, so two sweeps taken either side of a physical change can be
/// subtracted from each other.
///
/// This is the way in. The OBD port on this car carries no broadcast state —
/// pins 6/14 read 120 Ω, one terminator, a diagnostic stub — so the gate
/// latch and the belt buckles are not there to be overheard. They are there
/// to be asked for, by an identifier nobody publishes. Open the gate between
/// two sweeps and the identifier announces itself.
enum DIDScanner {
    static func run(
        nameHint: String?,
        first: UInt16,
        last: UInt16,
        passes: Int,
        tag: String?,
        compareTo: String?,
        includeVolatile: Bool
    ) async throws {
        let count = Int(last) - Int(first) + 1
        guard count > 0 else {
            print("Empty range: \(String(format: "%04X", first)) is past \(String(format: "%04X", last)).")
            exit(2)
        }

        // Each unanswered identifier costs the adapter's full response
        // timeout, so a wide sweep is minutes, not seconds. Say so up front —
        // this runs while someone stands in a driveway holding a tailgate.
        let estimate = Int(Double(count * passes) * 0.25)
        print("""
        Sweeping \(String(format: "0x%04X–0x%04X", first, last)) — \
        \(count) identifiers × \(passes) pass\(passes == 1 ? "" : "es") ≈ \(estimate / 60)m \(estimate % 60)s
        \(tag.map { "State: \($0)" } ?? "No --tag given; the diff will be harder to read later.")
        """)

        let transport = BLEELMTransport(nameHint: nameHint)
        transport.onStateChange = { print("  [ble] \($0.describedState)") }

        print("\nConnecting…")
        transport.connect()
        try await transport.waitUntilReady()

        // Pin protocol 6 rather than let the adapter hunt for it, and turn
        // headers on: one functional request draws answers from a dozen
        // modules, and the header is the only thing saying which said what.
        let session = ELM327Session(transport: transport)
        try await session.initialize(pinnedProtocol: 6)
        _ = try? await session.send("ATH1")

        var collected: [[DIDReply]] = []
        for pass in 1...passes {
            print("\nPass \(pass) of \(passes):")
            collected.append(try await sweep(session, first: first, last: last))
        }
        transport.disconnect()

        let snapshot = DIDSnapshot.merge(
            passes: collected,
            tag: tag,
            firstDID: first,
            lastDID: last,
            capturedAt: Date()
        )
        DIDReport.printSummary(snapshot)

        let path = try DIDReport.write(snapshot)
        print("\nSaved \(path)")

        // Compare against whatever was stored before this run — that's the
        // whole workflow, and making it automatic means one less thing to
        // remember while leaning into a car.
        let previous = compareTo ?? DIDReport.mostRecent(excluding: path)
        guard let previous else {
            print("""

            First sweep stored. Now change one thing — open the gate, unbuckle
            a belt — and run the same command again. The second run diffs
            itself against this one.
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

    /// One pass over the range. Reports as it goes, because a silent two
    /// minutes looks identical to a hang.
    private static func sweep(_ session: ELM327Session, first: UInt16, last: UInt16) async throws -> [DIDReply] {
        var replies: [DIDReply] = []
        var consecutiveFailures = 0
        var chunkAnswers = 0
        var chunkStart = first

        for did in first...last {
            do {
                let found = try await session.scanDID(did)
                consecutiveFailures = 0
                replies += found
                chunkAnswers += found.filter(\.isPositive).count
            } catch {
                consecutiveFailures += 1
                // A handful of timeouts is a busy bus; sixteen in a row is a
                // dropped link, and grinding through the rest wastes minutes.
                if consecutiveFailures >= 16 {
                    print("  ✗ 16 consecutive failures at \(String(format: "%04X", did)) — \(error)")
                    print("    Stopping this pass. Is the ignition still on?")
                    return replies
                }
            }

            if did % 16 == 15 || did == last {
                print(String(
                    format: "  %04X–%04X  %2d answered",
                    chunkStart, did, chunkAnswers
                ))
                chunkAnswers = 0
                chunkStart = did &+ 1
            }
        }
        return replies
    }
}
#endif
