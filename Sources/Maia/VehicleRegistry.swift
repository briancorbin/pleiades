import Foundation

/// Everything the car is known to expose, as a type rather than a document.
///
/// The same JSON that renders `docs/SIGNALS.md` is bundled into Maia, so the
/// app can browse it, the CLI can plan sweeps from it, and neither has to
/// keep its own copy. `RegistryDriftTests` asserts it agrees with
/// `ProprietarySignal`, so the catalogue the app polls and the sheet a human
/// reads can't disagree.
///
/// Most of what's in here is **not** pollable. 242 identifiers answer across
/// the mapped modules and about a dozen have known meanings; the rest are
/// recorded because "this identifier exists and we don't know what it does"
/// is a fact worth keeping, and a to-do list worth showing.
public struct VehicleRegistry: Sendable, Equatable {
    public let vehicle: Vehicle
    public let modules: [Module]
    public let openQuestions: [OpenQuestion]

    public struct Vehicle: Sendable, Equatable {
        public let year: Int
        public let model: String
        public let engine: String
        public let platform: String
        public let obdProtocol: String
    }

    /// How sure we are, in the order a reader cares about.
    public enum Confidence: String, Sendable, Comparable, CaseIterable {
        case confirmed
        case candidate
        case unidentified
        case rejected

        public var label: String {
            switch self {
            case .confirmed: "Confirmed"
            case .candidate: "Candidate"
            case .unidentified: "Unidentified"
            case .rejected: "Ruled out"
            }
        }

        /// Why a reader should or shouldn't trust it.
        public var detail: String {
            switch self {
            case .confirmed: "Measured, and told apart from the alternatives that could have explained the same result."
            case .candidate: "A specific prediction we haven't tested yet."
            case .unidentified: "The identifier answers. We don't know what it means."
            case .rejected: "Investigated and ruled out."
            }
        }

        private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    }

    public enum Provenance: String, Sendable {
        case measured, standard, community, inferred, invented

        public var label: String {
            switch self {
            case .measured: "Measured on this car"
            case .standard: "Public standard"
            case .community: "Third-party research"
            case .inferred: "Reasoned, untested"
            case .invented: "Our own identifier"
            }
        }
    }

    public struct Signal: Sendable, Equatable, Identifiable {
        public let did: UInt16
        public let name: String
        public let confidence: Confidence
        public let provenance: Provenance
        public let trueValue: String?
        public let method: String?
        public let evidence: String?
        public let note: String?
        public let date: String?

        public var id: UInt16 { did }
        public var command: String { String(format: "22%04X", did) }

        /// Whether Maia's catalogue knows how to read this one. Everything
        /// else is reference material until somebody measures it.
        public var isPollable: Bool {
            ProprietarySignal.all.contains { $0.id == did }
        }
    }

    public struct Module: Sendable, Equatable, Identifiable {
        public let address: UInt32
        public let name: String
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

        /// Answering identifiers minus the ones we've named — the size of
        /// what's left to find on this module.
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

    public static func bundled() throws -> VehicleRegistry {
        guard let url = Bundle.module.url(forResource: "signal-registry", withExtension: "json") else {
            throw OBDError.malformedResponse("signal-registry.json missing from the bundle")
        }
        return try VehicleRegistry(data: Data(contentsOf: url))
    }

    /// Cached, because SwiftUI will ask for this on every redraw.
    public static let shared: VehicleRegistry? = try? bundled()

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OBDError.malformedResponse("registry is not a JSON object")
        }

        let v = root["vehicle"] as? [String: Any] ?? [:]
        vehicle = Vehicle(
            year: v["year"] as? Int ?? 0,
            model: v["model"] as? String ?? "",
            engine: v["engine"] as? String ?? "",
            platform: v["platform"] as? String ?? "",
            obdProtocol: v["protocol"] as? String ?? ""
        )

        modules = ((root["modules"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let text = entry["address"] as? String,
                  let address = UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16)
            else { return nil }

            let signals = ((entry["signals"] as? [[String: Any]]) ?? []).compactMap { row -> Signal? in
                guard let didText = row["did"] as? String,
                      let did = UInt16(didText.replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { return nil }
                return Signal(
                    did: did,
                    name: (row["name"] as? String) ?? "?",
                    confidence: Confidence(rawValue: (row["confidence"] as? String) ?? "") ?? .unidentified,
                    provenance: Provenance(rawValue: (row["provenance"] as? String) ?? "") ?? .inferred,
                    trueValue: row["trueValue"] as? String,
                    method: row["method"] as? String,
                    evidence: row["evidence"] as? String,
                    note: row["note"] as? String,
                    date: row["date"] as? String
                )
            }

            return Module(
                address: address,
                name: (entry["name"] as? String) ?? "?",
                role: entry["role"] as? String,
                pages: (entry["pages"] as? [String]) ?? [],
                identifiersAnswering: entry["identifiersAnswering"] as? Int ?? 0,
                signals: signals.sorted { ($0.confidence, $0.did) < ($1.confidence, $1.did) },
                todo: entry["todo"] as? String
            )
        }
        .sorted { $0.address < $1.address }

        openQuestions = ((root["openQuestions"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let question = entry["question"] as? String else { return nil }
            return OpenQuestion(
                question: question,
                whyItMatters: entry["whyItMatters"] as? String,
                howToAnswer: entry["howToAnswer"] as? String
            )
        }
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
    /// The size of the work queue: identifiers that answer with no known meaning.
    public var unknownCount: Int { modules.reduce(0) { $0 + $1.unknownCount } }
}
