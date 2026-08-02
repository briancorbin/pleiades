#if canImport(CoreBluetooth)
import Foundation
import Maia

/// Runs a scripted capture session: the tool drives the procedure, the
/// operator just does what it says.
///
/// The difference from doing it by hand is not convenience, it's evidence
/// quality. Three things come free from scripting it:
///
/// - **Tags are correct by construction.** Today's belt captures are stuck at
///   `candidate` because nobody can now say whether each belt stayed fastened
///   as the next went on. A step that reads "fasten ONLY the driver belt"
///   cannot produce that ambiguity.
/// - **Every step is checked twice** — once on the change and again on the
///   revert. A byte that goes true when the door opens *and* false when it
///   shuts is confirmed. One that only does the first is a coincidence.
/// - **Predictions get tested.** A step can name the identifier we expect,
///   so the three inferred doors are promoted or killed automatically rather
///   than by someone squinting at a diff afterwards.
enum ProcedureRunner {
    static let path = "docs/capture-procedures.json"

    struct Step {
        let action: String
        let revert: String?
        let expect: String
        let candidate: UInt16?
    }

    struct Plan {
        let id: String
        let name: String
        let module: UInt32
        let note: String
        let steps: [Step]
    }

    // MARK: - Loading

    static func plans() throws -> [Plan] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["procedures"] as? [[String: Any]]
        else { throw RegistryError.malformed("no procedures array") }

        return list.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let module = (entry["module"] as? String).flatMap({
                      UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16)
                  })
            else { return nil }

            let steps = ((entry["steps"] as? [[String: Any]]) ?? []).compactMap { step -> Step? in
                guard let action = step["do"] as? String else { return nil }
                return Step(
                    action: action,
                    revert: step["undo"] as? String,
                    expect: (step["expect"] as? String) ?? "?",
                    candidate: (step["candidate"] as? String).flatMap {
                        UInt16($0.replacingOccurrences(of: "0x", with: ""), radix: 16)
                    }
                )
            }
            return Plan(
                id: id,
                name: (entry["name"] as? String) ?? id,
                module: module,
                note: (entry["note"] as? String) ?? "",
                steps: steps
            )
        }
    }

    static func list() throws {
        print("Capture procedures:\n")
        for plan in try plans() {
            print(String(
                format: "  %-10s %-24s module %03X · %d steps",
                (plan.id as NSString).utf8String!,
                (plan.name as NSString).utf8String!,
                plan.module, plan.steps.count
            ))
        }
        print("\n  ./scripts/did-procedure.sh <id>")
    }

    // MARK: - Running

    static func run(id: String, nameHint: String?, st: String, passes: Int) async throws {
        guard let plan = try plans().first(where: { $0.id == id }) else {
            print("No procedure called '\(id)'. Known:")
            try list()
            exit(2)
        }

        print("""

        \(plan.name) — module \(String(format: "%03X", plan.module)) (\(DIDEnumerator.name(plan.module)))
        \(plan.steps.count) steps.

        \(plan.note)

        Each step captures twice: once after you make the change, once after
        you put it back. A signal that moves both ways is confirmed; one that
        only moves once is a coincidence that happened to line up.
        """)

        let pages = DIDEnumerator.advertisedPages(for: plan.module)
            ?? [0x01, 0x02, 0x10, 0x11]
        print("Pages: \(pages.map { String(format: "%02X", $0) }.joined(separator: " "))\n")

        let transport = BLEELMTransport(nameHint: nameHint)
        transport.onStateChange = { print("  [ble] \($0.describedState)") }
        print("Connecting…")
        transport.connect()
        try await transport.waitUntilReady()

        let session = ELM327Session(transport: transport)
        try await session.initialize(pinnedProtocol: 6)
        try await DIDScanner.configure(session, st: st, extendedSession: false)
        _ = try? await session.send(String(format: "ATCRA%03X", plan.module))

        prompt("Put the car in its resting state — everything shut, nothing on — then press Enter for the baseline")
        let baseline = try await snapshot(session, plan: plan, pages: pages, tag: "baseline", passes: passes)
        print("  baseline: \(baseline.positives.count) identifiers\n")

        var findings: [(step: Step, moved: [DIDDelta], reverted: Bool)] = []

        for (index, step) in plan.steps.enumerated() {
            print(String(repeating: "─", count: 64))
            print("Step \(index + 1) of \(plan.steps.count) — \(step.expect)")
            prompt("  \(step.action)\n  Press Enter when done")

            let changed = try await snapshot(
                session, plan: plan, pages: pages, tag: step.expect, passes: passes
            )
            let moved = DIDScan.diff(from: baseline, to: changed)
            report(moved, step: step)

            var reverted = false
            if let revert = step.revert {
                prompt("  \(revert)\n  Press Enter when done")
                let back = try await snapshot(
                    session, plan: plan, pages: pages,
                    tag: "\(step.expect) reverted", passes: passes
                )
                let residue = DIDScan.diff(from: baseline, to: back)
                reverted = residue.isEmpty
                print(reverted
                      ? "  ✓ returned to baseline — the change tracks, it wasn't drift"
                      : "  ! \(residue.count) identifier(s) did NOT return: \(residue.map { String(format: "%04X", $0.did) }.joined(separator: " "))")
            }
            findings.append((step, moved, reverted))
            print("")
        }

        transport.disconnect()
        summarise(plan: plan, findings: findings)
    }

    private static func snapshot(
        _ session: ELM327Session, plan: Plan, pages: [UInt8], tag: String, passes: Int
    ) async throws -> DIDSnapshot {
        var collected: [[DIDReply]] = []
        for _ in 1...passes {
            var replies: [DIDReply] = []
            for page in pages {
                replies += try await DIDEnumerator.walkPage(session, page: page, quiet: true)
            }
            collected.append(replies)
        }
        let identifiers = collected.flatMap { $0 }.map(\.did)
        let snapshot = DIDSnapshot.merge(
            passes: collected, tag: "\(plan.id): \(tag)",
            firstDID: identifiers.min() ?? 0, lastDID: identifiers.max() ?? 0,
            capturedAt: Date()
        )
        _ = try? DIDReport.write(snapshot)
        return snapshot
    }

    private static func report(_ moved: [DIDDelta], step: Step) {
        guard !moved.isEmpty else {
            print("  nothing moved — this signal isn't on the pages we swept")
            return
        }
        for delta in moved {
            let hit = delta.did == step.candidate ? "   ← matches the prediction" : ""
            print(String(
                format: "  22 %04X @ %03X   %@ → %@%@",
                delta.did, delta.module,
                delta.before?.hexString ?? "—", delta.after?.hexString ?? "—", hit
            ))
        }
        if let candidate = step.candidate, !moved.contains(where: { $0.did == candidate }) {
            print(String(format: "  ✗ predicted %04X did not move — that guess was wrong", candidate))
        }
    }

    private static func summarise(
        plan: Plan, findings: [(step: Step, moved: [DIDDelta], reverted: Bool)]
    ) {
        print(String(repeating: "═", count: 64))
        print("  \(plan.name) — results")
        print(String(repeating: "═", count: 64) + "\n")

        for finding in findings {
            let ids = finding.moved.map { String(format: "%04X", $0.did) }
            let verdict: String
            if ids.isEmpty {
                verdict = "nothing moved"
            } else if finding.reverted, ids.count == 1 {
                verdict = "\(ids[0])  CONFIRMED (moved and returned)"
            } else if ids.count == 1 {
                verdict = "\(ids[0])  moved, revert not verified"
            } else {
                verdict = "\(ids.joined(separator: " "))  ambiguous — \(ids.count) moved together"
            }
            print(String(format: "  %-22s %@", (finding.step.expect as NSString).utf8String!, verdict))
        }

        let confirmed = findings.filter { $0.moved.count == 1 && $0.reverted }.count
        print("""

        \(confirmed) of \(findings.count) steps produced a single identifier that moved
        and returned. Those are confirmations, not correlations.

        Snapshots are in logs/ with the step names as tags. Paste this summary
        back into the session and the registry gets updated from it.
        """)
    }

    private static func prompt(_ message: String) {
        print("\n\(message) ", terminator: "")
        _ = readLine()
    }
}
#endif
