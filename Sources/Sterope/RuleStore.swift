import Foundation
import Maia

/// The persistence form of an AlertRule. Signals are stored by numeric id —
/// PID codes below 0x100, proprietary CAN signals above — and resolved at
/// load, so the JSON stays stable if decode closures change.
public struct StoredRule: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case above
        case below
    }

    public var id: String
    public var signalID: UInt16
    public var kind: Kind
    public var limit: Double
    public var clearMargin: Double
    public var severity: Severity
    public var message: String
    public var enabled: Bool
    public var sound: AlertSound
    /// 0…1.
    public var volume: Double

    public init(
        id: String = UUID().uuidString,
        signalID: UInt16,
        kind: Kind,
        limit: Double,
        clearMargin: Double,
        severity: Severity,
        message: String,
        enabled: Bool = true,
        sound: AlertSound = .silent,
        volume: Double = 1.0
    ) {
        self.id = id
        self.signalID = signalID
        self.kind = kind
        self.limit = limit
        self.clearMargin = clearMargin
        self.severity = severity
        self.message = message
        self.enabled = enabled
        self.sound = sound
        self.volume = volume
    }

    // Rule files written before sounds existed decode with the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Rule files written before proprietary signals existed key on
        // `pidCode`; PID codes are a subset of the signal id space.
        if let sid = try c.decodeIfPresent(UInt16.self, forKey: .signalID) {
            signalID = sid
        } else {
            signalID = UInt16(try c.decode(UInt8.self, forKey: .pidCode))
        }
        kind = try c.decode(Kind.self, forKey: .kind)
        limit = try c.decode(Double.self, forKey: .limit)
        clearMargin = try c.decode(Double.self, forKey: .clearMargin)
        severity = try c.decode(Severity.self, forKey: .severity)
        message = try c.decode(String.self, forKey: .message)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sound = try c.decodeIfPresent(AlertSound.self, forKey: .sound) ?? .silent
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
    }

    private enum CodingKeys: String, CodingKey {
        case id, signalID, pidCode, kind, limit, clearMargin
        case severity, message, enabled, sound, volume
    }

    // `pidCode` is read-only legacy — never written, so encoding is explicit.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(signalID, forKey: .signalID)
        try c.encode(kind, forKey: .kind)
        try c.encode(limit, forKey: .limit)
        try c.encode(clearMargin, forKey: .clearMargin)
        try c.encode(severity, forKey: .severity)
        try c.encode(message, forKey: .message)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sound, forKey: .sound)
        try c.encode(volume, forKey: .volume)
    }

    public init(from rule: AlertRule, enabled: Bool = true) {
        let kind: Kind
        let limit: Double
        switch rule.trigger {
        case .above(let l):
            kind = .above
            limit = l
        case .below(let l):
            kind = .below
            limit = l
        }
        self.init(
            id: rule.id, signalID: rule.signal.id, kind: kind, limit: limit,
            clearMargin: rule.clearMargin, severity: rule.severity,
            message: rule.message, enabled: enabled,
            sound: rule.sound, volume: rule.volume
        )
    }

    public var signal: SignalRef? {
        SignalRef.resolve(signalID)
    }

    /// Nil when disabled or the PID code isn't in the catalog.
    public func alertRule() -> AlertRule? {
        guard enabled, let signal else { return nil }
        return AlertRule(
            id: id, signal: signal,
            trigger: kind == .above ? .above(limit) : .below(limit),
            clearMargin: clearMargin, severity: severity, message: message,
            sound: sound, volume: volume
        )
    }

    public static func defaults() -> [StoredRule] {
        [AlertRule].foresterDefaults.map { StoredRule(from: $0) }
    }
}

public extension Array where Element == StoredRule {
    func alertRules() -> [AlertRule] {
        compactMap { $0.alertRule() }
    }
}

/// JSON-file-backed rule set. First launch seeds the Forester defaults.
public actor RuleStore {
    private let fileURL: URL
    private var rules: [StoredRule]

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pleiades", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("alert-rules.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([StoredRule].self, from: data) {
            rules = loaded
        } else {
            rules = StoredRule.defaults()
        }
    }

    public func all() -> [StoredRule] {
        rules
    }

    public func save(_ newRules: [StoredRule]) {
        rules = newRules
        persist()
    }

    @discardableResult
    public func resetToDefaults() -> [StoredRule] {
        rules = StoredRule.defaults()
        persist()
        return rules
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(rules).write(to: fileURL, options: .atomic)
    }
}
