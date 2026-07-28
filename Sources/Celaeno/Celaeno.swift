import Foundation

/// Celaeno — the dark one. An append-only archive of fault events that lives
/// outside the ECU: clearing codes wipes the car's memory, not this one.

/// One sample in a captured telemetry window.
public struct WindowSample: Sendable, Codable, Equatable {
    /// Seconds relative to the fault moment (negative = before it).
    public let t: Double
    /// PID hex, e.g. "0C".
    public let pid: String
    public let value: Double

    public init(t: Double, pid: String, value: Double) {
        self.t = t
        self.pid = pid
        self.value = value
    }
}

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
    /// Telemetry window around the fault (the black-box movie), attached
    /// once the post-window elapses. The ECU gives the instant; this gives
    /// the context.
    public let window: [WindowSample]?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        code: String,
        title: String,
        freezeFrame: [String: Double]? = nil,
        window: [WindowSample]? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.code = code
        self.title = title
        self.freezeFrame = freezeFrame
        self.window = window
    }
}

/// One fault lifecycle, presentation-ready: a stored event paired with the
/// cleared event that later resolved it (if any). The underlying log stays
/// double-entry; this is the grouped view.
public struct FaultOccurrence: Sendable, Identifiable, Equatable {
    public let id: UUID  // the stored event's id
    public let code: String
    public let title: String
    public let storedAt: Date
    public let clearedAt: Date?
    public let freezeFrame: [String: Double]?
    public let window: [WindowSample]?

    public var isActive: Bool { clearedAt == nil }
}

public extension Array where Element == DTCEvent {
    /// Pair each stored event with the next cleared event for the same code.
    /// Newest first.
    func occurrences() -> [FaultOccurrence] {
        var result: [FaultOccurrence] = []
        for event in sorted(by: { $0.date < $1.date }) {
            switch event.kind {
            case .stored:
                result.append(FaultOccurrence(
                    id: event.id, code: event.code, title: event.title,
                    storedAt: event.date, clearedAt: nil,
                    freezeFrame: event.freezeFrame, window: event.window
                ))
            case .cleared:
                if let open = result.lastIndex(where: { $0.code == event.code && $0.isActive }) {
                    let o = result[open]
                    result[open] = FaultOccurrence(
                        id: o.id, code: o.code, title: o.title,
                        storedAt: o.storedAt, clearedAt: event.date,
                        freezeFrame: o.freezeFrame, window: o.window
                    )
                }
            }
        }
        return result.reversed()
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

    /// Attach a telemetry window to an already-recorded event (the window
    /// finishes capturing after the event is first written).
    public func attachWindow(_ window: [WindowSample], toEventID id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let e = events[index]
        events[index] = DTCEvent(
            id: e.id, date: e.date, kind: e.kind, code: e.code, title: e.title,
            freezeFrame: e.freezeFrame, window: window
        )
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
