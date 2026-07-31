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
        includeVolatile: Bool,
        st: String,
        extendedSession: Bool,
        force: Bool,
        module: UInt32?
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

        let session = ELM327Session(transport: transport)
        try await session.initialize(pinnedProtocol: 6)
        try await configure(session, st: st, extendedSession: extendedSession)

        if let module {
            // Narrow to one module. Fifteen answering the same request at once
            // costs responses — the support bitmasks advertise identifiers that
            // several modules then never got a word in edgewise about.
            _ = try? await session.send(String(format: "ATCRA%03X", module))
            print("  listening only to \(String(format: "%03X", module))")
        }

        guard try await preflight(session, force: force || module != nil) else {
            transport.disconnect()
            return
        }

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

    /// Set the adapter up to hear the whole car rather than just the engine.
    ///
    /// The first sweep of this range came back with answers from exactly one
    /// module, and the reason is the single most important thing to know
    /// about scanning a car through an ELM327: **in protocol 6 the adapter's
    /// CAN receive filter accepts only 0x7E8–0x7EF**, the response window the
    /// emissions standard reserves. Body, chassis and comfort modules live at
    /// 0x71F, 0x74A, 0x78E and friends, outside it. They answer — Merope
    /// watched fourteen of them answer this exact request, listening
    /// promiscuously — and the dongle discards every one before we see it.
    static func configure(_ session: ELM327Session, st: String, extendedSession: Bool) async throws {
        // Headers on: one functional request draws answers from a dozen
        // modules, and the header is the only thing saying which said what.
        _ = try? await session.send("ATH1")

        // Fixed timing, not adaptive. Adaptive timing tunes the wait from
        // observed response times, which is right when one ECU answers and
        // wrong here — it would return as soon as the fastest module replies
        // and cut off the thirteen behind it.
        _ = try? await session.send("ATAT0")
        _ = try? await session.send("ATST\(st)")

        // Widen the receive filter to 0x700–0x7FF. Same call the app makes,
        // for the same reason: the body modules are outside the OBD window.
        print("\nOpening the receive filter past the OBD window:")
        let opened = (try? await session.openReceiveFilter()) ?? false
        print("  \(opened ? "widened to 0x700–0x7FF" : "✗ the adapter refused — it can only hear 0x7E8–0x7EF")")

        guard extendedSession else { return }
        // Opt-in: some identifiers only answer outside the default session.
        // Left off by default because it changes the car's state rather than
        // just reading it, and needs tester-present traffic to stay open.
        let entered = (try? await session.send("1003")) ?? "?"
        print("  extended diagnostic session (10 03) → \(clean(entered))")
    }

    /// Ask one identifier and count who answers, before committing to
    /// hundreds of them. Two minutes is a long time to spend finding out the
    /// adapter was deaf the whole way through.
    private static func preflight(_ session: ELM327Session, force: Bool) async throws -> Bool {
        print("\nPreflight — asking 22 0100 and counting who answers:")
        let raw = (try? await session.send("220100")) ?? ""
        for line in raw.split(whereSeparator: \.isNewline) where !clean(String(line)).isEmpty {
            print("    \(clean(String(line)))")
        }

        let replies = DIDScan.replies(to: 0x0100, in: raw)
        let modules = Set(replies.map(\.module)).sorted()
        print("  \(modules.count) module\(modules.count == 1 ? "" : "s") answered: \(modules.map { String(format: "%03X", $0) }.joined(separator: " "))")

        guard modules.count < 3, !force else { return true }

        print("""

        Stopping — that's the engine talking to itself.

        Merope saw fourteen modules answer this exact request while listening
        with no filter, so the data is there; the adapter is dropping it. If
        the ATCF/ATCM lines above came back '?', this dongle won't widen its
        filter, and the sweep would spend two minutes confirming it.

        Options, in order of effort:
          · Try --st 64 first — a slower module may simply be late.
          · Run the sweep through Merope instead. It has no receive filter,
            which is exactly how we know these modules answer at all.
          · --force sweeps anyway if you want the ECM's own identifiers.
        """)
        return false
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
