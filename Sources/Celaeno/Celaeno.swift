import Foundation

/// Celaeno — the dark one. An append-only archive of fault events that lives
/// outside the ECU: clearing codes wipes the car's memory, not this one.

public struct DTCEvent: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case stored
        case cleared
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let code: String
    public let title: String
    /// PID hex (e.g. "0C") → decoded value, from the freeze frame captured
    /// when the code set. Nil for cleared events or when no frame existed.
    public let freezeFrame: [String: Double]?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        code: String,
        title: String,
        freezeFrame: [String: Double]? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.code = code
        self.title = title
        self.freezeFrame = freezeFrame
    }
}

/// JSON-file-backed event log. Default location is Application Support;
/// tests inject a scratch directory.
public actor DTCEventStore {
    private let fileURL: URL
    private var events: [DTCEvent]

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pleiades", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("dtc-history.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([DTCEvent].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public func record(_ event: DTCEvent) {
        events.append(event)
        persist()
    }

    /// Newest first. Events append chronologically, so insertion order breaks
    /// ties between same-timestamp events (a date sort alone is unstable).
    public func all() -> [DTCEvent] {
        events.reversed()
    }

    /// The most recent event kind for a code — used to avoid duplicate
    /// stored/cleared entries across app launches.
    public func lastKind(for code: String) -> DTCEvent.Kind? {
        events.last { $0.code == code }?.kind
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(events).write(to: fileURL, options: .atomic)
    }
}
