import Foundation

/// One sample in a recorded drive.
public struct DriveSample: Sendable, Codable, Equatable {
    /// Seconds since the session started.
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

/// A recorded drive: everything the poll loop saw, start to stop.
public struct DriveSession: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var samples: [DriveSample]

    public init(id: UUID = UUID(), startedAt: Date = Date(), endedAt: Date? = nil, samples: [DriveSample] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
    }

    public var duration: TimeInterval {
        if let endedAt {
            return endedAt.timeIntervalSince(startedAt)
        }
        return samples.last?.t ?? 0
    }
}

/// One JSON file per session under `drives/`. Celaeno keeps the movies too.
public actor DriveStore {
    private let directory: URL
    private var active: DriveSession?

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pleiades", isDirectory: true)
        self.directory = base.appendingPathComponent("drives", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func begin() -> DriveSession {
        let session = DriveSession()
        active = session
        persist(session)
        return session
    }

    public func append(_ samples: [DriveSample]) {
        guard var session = active, !samples.isEmpty else { return }
        session.samples.append(contentsOf: samples)
        active = session
        persist(session)
    }

    @discardableResult
    public func end() -> DriveSession? {
        guard var session = active else { return nil }
        session.endedAt = Date()
        persist(session)
        active = nil
        return session
    }

    /// Newest first.
    public func list() -> [DriveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(DriveSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        if active?.id == id {
            active = nil
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ session: DriveSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(session).write(to: fileURL(for: session.id), options: .atomic)
    }
}
