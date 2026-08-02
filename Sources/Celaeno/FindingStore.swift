import Foundation

/// Names Brian gave to identifiers while sitting in the car.
///
/// The signal registry is a bundled read-only resource, so a discovery made
/// on the iPad can't be written back into it directly. This is the layer that
/// holds those findings until they can be — and the export is deliberately
/// shaped as something to paste back into a session, so a finding made in a
/// driveway ends up in the repo with its evidence rather than in someone's
/// memory.
public struct Finding: Codable, Sendable, Equatable, Identifiable {
    public let did: UInt16
    public let module: UInt32
    /// What Brian said it is.
    public var name: String
    /// The states it was seen in, in order — "gate closed" then "gate open".
    public var observedIn: [String]
    /// Bytes before and after, as hex, for whichever change named it.
    public var before: String?
    public var after: String?
    /// True once it's been seen to change *and* change back. One direction is
    /// a correlation; both is a measurement.
    public var reverted: Bool
    public var note: String?
    public let discoveredAt: Date

    public var id: String { String(format: "%03X:%04X", module, did) }

    public init(
        did: UInt16,
        module: UInt32,
        name: String,
        observedIn: [String] = [],
        before: String? = nil,
        after: String? = nil,
        reverted: Bool = false,
        note: String? = nil,
        discoveredAt: Date = Date()
    ) {
        self.did = did
        self.module = module
        self.name = name
        self.observedIn = observedIn
        self.before = before
        self.after = after
        self.reverted = reverted
        self.note = note
        self.discoveredAt = discoveredAt
    }

    /// What the registry would call this: seen both ways is a candidate worth
    /// promoting; seen once is a guess.
    public var confidence: String { reverted ? "candidate" : "unidentified" }
}

public actor FindingStore {
    private let url: URL
    private var findings: [Finding] = []

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Pleiades", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("findings.json")

        // The decoder's date strategy has to match the encoder's below. It
        // didn't, and the failure mode was silent: encode wrote ISO8601
        // strings, decode expected a number, `try?` swallowed the mismatch,
        // and every finding vanished on relaunch — the exact moment you'd
        // least want to lose them.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let stored = try? decoder.decode([Finding].self, from: data) {
            findings = stored
        }
    }

    public func all() -> [Finding] {
        findings.sorted { $0.discoveredAt > $1.discoveredAt }
    }

    public func record(_ finding: Finding) {
        // Re-naming an identifier replaces the old entry rather than stacking
        // a second opinion next to it.
        findings.removeAll { $0.id == finding.id }
        findings.append(finding)
        persist()
    }

    public func remove(_ id: String) {
        findings.removeAll { $0.id == id }
        persist()
    }

    public func removeAll() {
        findings.removeAll()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(findings).write(to: url)
    }

    /// A registry fragment, ready to paste back into a session.
    ///
    /// Not applied automatically: a finding made in a driveway still has to
    /// meet the registry's standard — measured, dated, with evidence — and
    /// that's a judgement, not a file write.
    public func exportPatch() -> String {
        let grouped = Dictionary(grouping: findings, by: \.module)
        var lines = [
            "// Findings from the iPad. Paste this into a session to fold it",
            "// into Sources/Maia/Resources/signal-registry.json.",
            "",
        ]
        for module in grouped.keys.sorted() {
            lines.append(String(format: "module %03X:", module))
            for finding in (grouped[module] ?? []).sorted(by: { $0.did < $1.did }) {
                let states = finding.observedIn.joined(separator: " → ")
                let change = [finding.before, finding.after].compactMap { $0 }.joined(separator: " → ")
                lines.append(String(
                    format: "  22 %04X  %@  [%@]  %@%@",
                    finding.did,
                    finding.name,
                    finding.confidence,
                    change.isEmpty ? "" : "\(change)  ",
                    states.isEmpty ? "" : "(\(states))"
                ))
                if let note = finding.note, !note.isEmpty {
                    lines.append("            note: \(note)")
                }
            }
        }
        if findings.isEmpty {
            lines.append("(nothing recorded yet)")
        }
        return lines.joined(separator: "\n")
    }
}
