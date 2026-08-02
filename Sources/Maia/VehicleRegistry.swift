import Foundation

/// A community description of what a platform's modules will tell you, and
/// how anybody knows. Format spec: `docs/registry-format.md`.
///
/// The organising idea is that **confidence is derived, never asserted**. A
/// contribution isn't "this is the tailgate", it's "here is what I did and
/// what happened" — so you can't mark something confirmed, you can only
/// record evidence good enough that it becomes confirmed. Two people on two
/// different cars reaching the same answer is expressible, and stronger than
/// either alone.
public struct VehicleRegistry: Sendable, Equatable {
    public let schema: String
    public let platform: Platform
    public let contributors: [Contributor]
    public let modules: [Module]
    public let openQuestions: [OpenQuestion]

    public struct Platform: Sendable, Equatable {
        public let id: String
        public let name: String
        public let models: [String]
        public let elm327Protocol: Int?
        public let protocolDescription: String
        /// Module addresses that answer `22 F197`. Plug into an unknown car,
        /// scan, and match — so nobody picks their model from a dropdown.
        public let fingerprint: [UInt32]
        /// Partial match on purpose: trim levels differ, and a car without
        /// blind-spot radar shouldn't fail to match a registry listing it.
        public let minimumMatch: Double
    }

    public struct Contributor: Sendable, Equatable {
        public let id: String
        public let vehicles: [String]
    }

    /// What somebody did, and what happened. The unit of contribution.
    public struct Observation: Sendable, Equatable {
        public let by: String
        public let vehicle: String?
        public let date: String
        public let method: String?
        public let evidence: String?
        /// Seen to change **and change back**. This is the whole ballgame: a
        /// byte that goes true when the gate opens is a correlation, one that
        /// goes false again when it shuts is a measurement.
        public let reverted: Bool
        /// Identifiers that moved at the same time and were ruled out — so
        /// the next person doesn't repeat the elimination.
        public let discriminated: [String]
        /// Investigated and found to be noise.
        public let rejected: Bool
    }

    /// How to turn bytes into a value. Declared per signal because it is not
    /// consistent within a car: `0x75A` says `00`/`FF`, `0x788` says
    /// `01`/`02`, and assuming "non-zero is true" reports every unfastened
    /// seatbelt as fastened.
    public enum Encoding: Sendable, Equatable {
        case boolean(trueValue: UInt8, falseValue: UInt8?)
        case scaled(divisor: Double, unit: String, bytes: Int)
        case enumerated([UInt8: String])
        /// The honest default for identifiers that answer with no known
        /// meaning. They belong here — that's a fact, and a work queue.
        case raw

        public var isBoolean: Bool {
            if case .boolean = self { return true }
            return false
        }
    }

    public struct Access: Sendable, Equatable {
        public let read: Bool
        public let write: Bool
        /// Set when a module demands `27` before accepting a write, so a tool
        /// can say so rather than failing opaquely.
        public let securityAccess: String?
    }

    public enum Confidence: String, Sendable, Comparable, CaseIterable {
        case confirmed, candidate, unidentified, rejected

        public var label: String {
            switch self {
            case .confirmed: "Confirmed"
            case .candidate: "Candidate"
            case .unidentified: "Unidentified"
            case .rejected: "Ruled out"
            }
        }

        public var detail: String {
            switch self {
            case .confirmed: "Seen to change and change back, or reproduced by a second contributor."
            case .candidate: "Observed once, never seen to revert."
            case .unidentified: "The identifier answers. Nobody has explained it."
            case .rejected: "Investigated and found to be noise."
            }
        }

        private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    }

    public struct Signal: Sendable, Equatable, Identifiable {
        public let did: UInt16
        public let name: String
        public let encoding: Encoding
        public let access: Access
        public let observations: [Observation]
        /// What we'd expect, for signals nobody has measured. Explicitly not
        /// an observation — a prediction never earns confidence.
        public let prediction: String?
        public let note: String?

        public var id: UInt16 { did }
        public var command: String { String(format: "22%04X", did) }

        /// **Computed, never stored.** See `docs/registry-format.md`.
        public var confidence: Confidence {
            if observations.contains(where: \.rejected) { return .rejected }
            if observations.contains(where: \.reverted) { return .confirmed }
            if Set(observations.map(\.by)).count >= 2 { return .confirmed }
            return observations.isEmpty ? .unidentified : .candidate
        }

        public var firstObservation: Observation? { observations.first }
        public var date: String? { firstObservation?.date }
        public var method: String? { firstObservation?.method ?? prediction }
        public var evidence: String? { firstObservation?.evidence }

        /// Independent reproduction — the strongest claim this format carries.
        public var contributorCount: Int { Set(observations.map(\.by)).count }

        public var isPollable: Bool {
            ProprietarySignal.all.contains { $0.id == did }
        }

        /// Writing to a misidentified identifier can misconfigure a restraint
        /// system on a car belonging to someone who trusted this data. Reading
        /// one costs a number you misinterpret.
        public var isWritable: Bool { access.write && confidence == .confirmed }
    }

    public struct Module: Sendable, Equatable, Identifiable {
        public let address: UInt32
        public let name: String
        public let nameSource: String
        public let role: String?
        public let pages: [String]
        public let identifiersAnswering: Int
        public let signals: [Signal]
        public let todo: String?

        public var id: UInt32 { address }
        public var label: String { String(format: "%03X", address) }

        public func count(_ confidence: Confidence) -> Int {
            signals.filter { $0.confidence == confidence }.count
        }

        /// Identifiers that answer with no known meaning — what's left to find.
        public var unknownCount: Int {
            max(0, identifiersAnswering - count(.confirmed) - count(.candidate))
        }
    }

    public struct OpenQuestion: Sendable, Equatable, Identifiable {
        public let question: String
        public let whyItMatters: String?
        public let howToAnswer: String?
        public var id: String { question }
    }

    // MARK: - Loading

    /// Every platform registry bundled with the app.
    public static func allBundled() -> [VehicleRegistry] {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "json", subdirectory: "registry"
        ) else { return [] }
        return urls.compactMap { try? VehicleRegistry(data: Data(contentsOf: $0)) }
            .sorted { $0.platform.id < $1.platform.id }
    }

    public static let all: [VehicleRegistry] = allBundled()

    /// The single registry, while there's only one platform. Views that
    /// haven't been taught to pick yet use this.
    public static var shared: VehicleRegistry? { all.first }

    /// Which platform is this car? Matched on the set of modules that
    /// answered, so an unknown car identifies itself.
    public static func match(respondingModules: Set<UInt32>) -> VehicleRegistry? {
        all
            .map { ($0, $0.matchScore(respondingModules)) }
            .filter { $0.1 >= $0.0.platform.minimumMatch }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func matchScore(_ responding: Set<UInt32>) -> Double {
        let expected = Set(platform.fingerprint)
        guard !expected.isEmpty else { return 0 }
        return Double(expected.intersection(responding).count) / Double(expected.count)
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OBDError.malformedResponse("registry is not a JSON object")
        }
        schema = (root["schema"] as? String) ?? "unknown"

        let p = root["platform"] as? [String: Any] ?? [:]
        let fp = p["fingerprint"] as? [String: Any] ?? [:]
        let proto = p["protocol"] as? [String: Any] ?? [:]
        platform = Platform(
            id: (p["id"] as? String) ?? "unknown",
            name: (p["name"] as? String) ?? "",
            models: (p["models"] as? [String]) ?? [],
            elm327Protocol: proto["elm327"] as? Int,
            protocolDescription: (proto["description"] as? String) ?? "",
            fingerprint: ((fp["respondingModules"] as? [String]) ?? []).compactMap(Self.hex32),
            minimumMatch: (fp["minimumMatch"] as? Double) ?? 0.8
        )

        contributors = ((root["contributors"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return Contributor(id: id, vehicles: ($0["vehicles"] as? [String]) ?? [])
        }

        modules = ((root["modules"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let address = (entry["address"] as? String).flatMap(Self.hex32) else { return nil }
            let signals = ((entry["signals"] as? [[String: Any]]) ?? [])
                .compactMap(Self.signal)
                .sorted { ($0.confidence, $0.did) < ($1.confidence, $1.did) }
            return Module(
                address: address,
                name: (entry["name"] as? String) ?? "?",
                nameSource: (entry["nameSource"] as? String) ?? "unknown",
                role: entry["role"] as? String,
                pages: (entry["pages"] as? [String]) ?? [],
                identifiersAnswering: entry["identifiersAnswering"] as? Int ?? 0,
                signals: signals,
                todo: entry["todo"] as? String
            )
        }
        .sorted { $0.address < $1.address }

        openQuestions = ((root["openQuestions"] as? [[String: Any]]) ?? []).compactMap {
            guard let question = $0["question"] as? String else { return nil }
            return OpenQuestion(
                question: question,
                whyItMatters: $0["whyItMatters"] as? String,
                howToAnswer: $0["howToAnswer"] as? String
            )
        }
    }

    private static func signal(_ row: [String: Any]) -> Signal? {
        guard let did = (row["did"] as? String).flatMap(hex16) else { return nil }
        let access = row["access"] as? [String: Any] ?? [:]
        return Signal(
            did: did,
            name: (row["name"] as? String) ?? "?",
            encoding: encoding(row["encoding"] as? [String: Any] ?? [:]),
            access: Access(
                read: (access["read"] as? Bool) ?? true,
                write: (access["write"] as? Bool) ?? false,
                securityAccess: access["securityAccess"] as? String
            ),
            observations: ((row["observations"] as? [[String: Any]]) ?? []).compactMap(observation),
            prediction: row["prediction"] as? String,
            note: row["note"] as? String
        )
    }

    private static func observation(_ row: [String: Any]) -> Observation? {
        guard let by = row["by"] as? String, let date = row["date"] as? String else { return nil }
        return Observation(
            by: by,
            vehicle: row["vehicle"] as? String,
            date: date,
            method: row["method"] as? String,
            evidence: row["evidence"] as? String,
            reverted: (row["reverted"] as? Bool) ?? false,
            discriminated: (row["discriminated"] as? [String]) ?? [],
            rejected: (row["rejected"] as? Bool) ?? false
        )
    }

    private static func encoding(_ row: [String: Any]) -> Encoding {
        switch row["kind"] as? String {
        case "boolean":
            return .boolean(
                trueValue: (row["trueValue"] as? String).flatMap { UInt8($0, radix: 16) } ?? 1,
                falseValue: (row["falseValue"] as? String).flatMap { UInt8($0, radix: 16) }
            )
        case "scaled":
            return .scaled(
                divisor: (row["divisor"] as? Double) ?? 1,
                unit: (row["unit"] as? String) ?? "",
                bytes: (row["bytes"] as? Int) ?? 2
            )
        case "enum":
            var values: [UInt8: String] = [:]
            for (key, name) in (row["values"] as? [String: String]) ?? [:] {
                if let byte = UInt8(key, radix: 16) { values[byte] = name }
            }
            return .enumerated(values)
        default:
            return .raw
        }
    }

    private static func hex16(_ text: String) -> UInt16? {
        UInt16(text.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    private static func hex32(_ text: String) -> UInt32? {
        UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    // MARK: - Queries

    public func module(at address: UInt32) -> Module? {
        modules.first { $0.address == address }
    }

    public func signal(_ did: UInt16) -> (module: Module, signal: Signal)? {
        for module in modules {
            if let signal = module.signals.first(where: { $0.did == did }) {
                return (module, signal)
            }
        }
        return nil
    }

    public var totalSignals: Int { modules.reduce(0) { $0 + $1.signals.count } }
    public var totalAnswering: Int { modules.reduce(0) { $0 + $1.identifiersAnswering } }
    public func count(_ confidence: Confidence) -> Int {
        modules.reduce(0) { $0 + $1.count(confidence) }
    }
    public var unknownCount: Int { modules.reduce(0) { $0 + $1.unknownCount } }
}
