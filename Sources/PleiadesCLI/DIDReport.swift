import Foundation
import Maia

/// Snapshot storage and the human-facing rendering of a DID sweep.
///
/// Deliberately free of CoreBluetooth so `pleiades compare a.json b.json`
/// works anywhere, including on a machine that has never seen the car.
enum DIDReport {
    static let directory = "logs"

    // MARK: - Files

    static func write(_ snapshot: DIDSnapshot) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let path = "\(directory)/did-\(stamp.string(from: snapshot.capturedAt)).json"
        try snapshot.encoded().write(to: URL(fileURLWithPath: path))
        return path
    }

    static func load(_ path: String) throws -> DIDSnapshot {
        try DIDSnapshot(json: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// The most recent stored sweep, for the mark/diff workflow: scan, change
    /// one thing about the car, scan again, and the second scan finds the
    /// first one on its own.
    static func mostRecent(excluding excluded: String? = nil) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { $0.hasPrefix("did-") && $0.hasSuffix(".json") }
            .map { "\(directory)/\($0)" }
            .filter { $0 != excluded }
            .sorted() // timestamped names sort chronologically
            .last
    }

    // MARK: - Rendering

    static func printSummary(_ snapshot: DIDSnapshot) {
        let positives = snapshot.positives
        let steady = positives.filter { !$0.volatile }
        print("""

        \(String(format: "0x%04X–0x%04X", snapshot.firstDID, snapshot.lastDID)) \
        · \(snapshot.passes) pass\(snapshot.passes == 1 ? "" : "es")\
        \(snapshot.tag.map { " · \($0)" } ?? "")
          \(positives.count) identifiers answered across \(snapshot.modules.count) modules
          \(steady.count) held still between passes, \(positives.count - steady.count) moved on their own
        """)

        guard !positives.isEmpty else { return }
        print("\nModules answering:")
        for module in snapshot.modules {
            let mine = positives.filter { $0.module == module }
            guard !mine.isEmpty else { continue }
            let list = mine.prefix(8).map { String(format: "%04X", $0.did) }.joined(separator: " ")
            let more = mine.count > 8 ? " …+\(mine.count - 8)" : ""
            print(String(format: "  %03X  %2d  %@%@", module, mine.count, list, more))
        }
    }

    /// The payoff. Everything else exists to make these few lines trustworthy.
    static func printDiff(from before: DIDSnapshot, to after: DIDSnapshot, includeVolatile: Bool) {
        let deltas = DIDScan.diff(from: before, to: after, includeVolatile: includeVolatile)

        print("\n" + String(repeating: "─", count: 60))
        print("  \(before.tag ?? "before")   →   \(after.tag ?? "after")")
        print(String(repeating: "─", count: 60))

        guard !deltas.isEmpty else {
            print("""

            Nothing moved.

            Either the identifier for what you changed is outside this range,
            or it lives on a bus the OBD port can't reach. Widen the range
            before concluding the second one.
            """)
            return
        }

        print("")
        for delta in deltas {
            let flag = delta.volatile ? "  (volatile)" : ""
            print(String(format: "  22 %04X @ %03X   %@%@", delta.did, delta.module, delta.kind.rawValue, flag))
            let before = delta.before?.hexString ?? "—"
            let after = delta.after?.hexString ?? "—"
            print("     before  \(before)")
            print("     after   \(after)")
            if delta.kind == .changed {
                print("             \(carets(delta.changedByteIndices))")
            }
            print("")
        }

        let steady = deltas.filter { !$0.volatile }
        if steady.count == 1, let hit = steady.first {
            print("""
            One identifier moved and nothing else did. That's the signal —
            \(String(format: "22 %04X", hit.did)) on module \(String(format: "%03X", hit.module)).
            Change the same thing back and re-scan to confirm it tracks.
            """)
        } else if !includeVolatile {
            print("Volatile identifiers hidden. Re-run with --include-volatile to see them.")
        }
    }

    /// `^^` under each changed byte — the same mark the recon firmware uses,
    /// because you end up reading both in the same afternoon.
    static func carets(_ indices: [Int]) -> String {
        guard let last = indices.max() else { return "" }
        var line = Array(repeating: Character(" "), count: last * 3 + 2)
        for index in indices {
            line[index * 3] = "^"
            line[index * 3 + 1] = "^"
        }
        return String(line)
    }
}
