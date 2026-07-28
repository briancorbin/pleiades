import Celaeno
import Foundation
import Maia
import Sterope

/// Polls the session and publishes decoded readings for the views.
/// Fast PIDs refresh at 10 Hz, slow ones at 1 Hz; DTC/MIL state rides the
/// slow cadence, and Sterope evaluates after every poll.
@MainActor
public final class TelemetryModel: ObservableObject {
    @Published public private(set) var readings: [UInt8: Double] = [:]
    @Published public private(set) var alerts: [Alert] = []
    @Published public private(set) var mil: MILStatus?
    @Published public private(set) var dtcs: [DTC] = []
    @Published public private(set) var freezeFrame: [UInt8: Double] = [:]
    @Published public private(set) var freezeDTC: DTC?
    /// Celaeno's archive, newest first. Survives code clearing.
    @Published public private(set) var history: [DTCEvent] = []

    public let freezeFramePIDs: [PID] = [.rpm, .speed, .coolantTemp, .engineLoad, .throttle]

    public let fastPIDs: [PID] = [.rpm, .speed, .throttle, .engineLoad]
    public let slowPIDs: [PID] = [
        .coolantTemp, .oilTemp, .controlModuleVoltage, .intakeAirTemp,
        .ambientAirTemp, .fuelLevel, .manifoldPressure, .timingAdvance,
        .runTime, .distanceWithMIL, .distanceSinceCleared,
    ]

    public let sourceLabel: String

    private let source: any TelemetrySource
    private let eventStore: DTCEventStore
    private var sterope: SteropeEngine
    private var loop: Task<Void, Never>?
    private var isInitialized = false

    // The Merope pattern in Swift: while the app is connected it keeps its
    // own rolling telemetry ring, so fault events get a pre/post window, not
    // just the ECU's single-instant freeze frame.
    private struct RingEntry {
        let date: Date
        let pid: UInt8
        let value: Double
    }

    private var ring: [RingEntry] = []
    private var pendingWindows: [(eventID: UUID, trigger: Date)] = []
    private let windowPre: TimeInterval
    private let windowPost: TimeInterval

    private let ruleStore: RuleStore?

    // Drive recording: while on, every decoded reading also lands in the
    // active DriveSession, flushed to disk in batches.
    @Published public private(set) var isRecording = false
    public let driveStore: DriveStore
    private var driveStart: Date?
    private var driveBuffer: [DriveSample] = []
    private var lastDriveFlush = Date()
    private let driveFlushInterval: TimeInterval

    public init(
        source: any TelemetrySource,
        rules: [AlertRule] = .foresterDefaults,
        ruleStore: RuleStore? = nil,
        historyDirectory: URL? = nil,
        drivesDirectory: URL? = nil,
        windowPre: TimeInterval = 45,
        windowPost: TimeInterval = 15,
        driveFlushInterval: TimeInterval = 5
    ) {
        self.source = source
        self.sourceLabel = source.label
        self.sterope = SteropeEngine(rules: rules)
        self.ruleStore = ruleStore
        self.eventStore = DTCEventStore(directory: historyDirectory)
        self.driveStore = DriveStore(directory: drivesDirectory)
        self.windowPre = windowPre
        self.windowPost = windowPost
        self.driveFlushInterval = driveFlushInterval
    }

    public func startRecording() async {
        guard !isRecording else { return }
        let session = await driveStore.begin()
        driveStart = session.startedAt
        driveBuffer = []
        lastDriveFlush = Date()
        isRecording = true
    }

    public func stopRecording() async {
        guard isRecording else { return }
        await driveStore.append(driveBuffer)
        driveBuffer = []
        await driveStore.end()
        driveStart = nil
        isRecording = false
    }

    /// Swap the live rule set (e.g. after edits in the Alerts tab).
    /// Hysteresis state resets — acceptable, the rules just changed.
    public func setRules(_ rules: [AlertRule]) {
        sterope = SteropeEngine(rules: rules)
        alerts = sterope.evaluate(readings)
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                await self?.poll(fast: true, slow: tickCount % 10 == 0)
                tickCount += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One poll cycle. Public so tests can drive the model without the timer.
    public func poll(fast: Bool = true, slow: Bool = false) async {
        if !isInitialized {
            try? await source.session.initialize()
            history = await eventStore.all()
            if let ruleStore {
                sterope = SteropeEngine(rules: await ruleStore.all().alertRules())
            }
            isInitialized = true
        }
        await source.tick(dt: 0.1)
        var pids: [PID] = fast ? fastPIDs : []
        if slow { pids += slowPIDs }
        let now = Date()
        for pid in pids {
            if let reading = try? await source.session.read(pid) {
                readings[pid.code] = reading.value
                ring.append(RingEntry(date: now, pid: pid.code, value: reading.value))
                if isRecording, let driveStart {
                    driveBuffer.append(DriveSample(
                        t: now.timeIntervalSince(driveStart),
                        pid: String(format: "%02X", pid.code),
                        value: reading.value
                    ))
                }
            }
        }
        if isRecording, now.timeIntervalSince(lastDriveFlush) >= driveFlushInterval {
            await driveStore.append(driveBuffer)
            driveBuffer = []
            lastDriveFlush = now
        }
        let cutoff = now.addingTimeInterval(-(windowPre + windowPost + 30))
        while let first = ring.first, first.date < cutoff {
            ring.removeFirst()
        }
        if slow {
            mil = try? await source.session.milStatus()
            let current = (try? await source.session.readDTCs()) ?? []
            await refreshFreezeFrame(hasCodes: !current.isEmpty)
            await recordTransitions(from: dtcs, to: current)
            dtcs = current
        }
        await flushDueWindows()
        alerts = sterope.evaluate(readings)
    }

    /// Deliberate user action from the DTC row — clears codes and re-reads.
    public func clearDTCs() async {
        try? await source.session.clearDTCs()
        await recordTransitions(from: dtcs, to: [])
        mil = try? await source.session.milStatus()
        dtcs = (try? await source.session.readDTCs()) ?? []
        freezeFrame = [:]
        freezeDTC = nil
    }

    private func refreshFreezeFrame(hasCodes: Bool) async {
        guard hasCodes else {
            freezeFrame = [:]
            freezeDTC = nil
            return
        }
        freezeDTC = (try? await source.session.freezeFrameDTC()) ?? nil
        var frame: [UInt8: Double] = [:]
        for pid in freezeFramePIDs {
            if let reading = try? await source.session.readFreezeFrame(pid) {
                frame[pid.code] = reading.value
            }
        }
        freezeFrame = frame
    }

    /// Archive stored/cleared transitions in Celaeno, deduped against the
    /// archive's last-known state so app relaunches don't double-record.
    private func recordTransitions(from old: [DTC], to new: [DTC]) async {
        let oldCodes = Set(old.map(\.code))
        let newCodes = Set(new.map(\.code))
        var changed = false
        for dtc in new where !oldCodes.contains(dtc.code) {
            guard await eventStore.lastKind(for: dtc.code) != .stored else { continue }
            let frame = freezeDTC?.code == dtc.code && !freezeFrame.isEmpty
                ? Dictionary(uniqueKeysWithValues: freezeFrame.map { (String(format: "%02X", $0.key), $0.value) })
                : nil
            let event = DTCEvent(kind: .stored, code: dtc.code, title: dtc.info.title, freezeFrame: frame)
            await eventStore.record(event)
            pendingWindows.append((eventID: event.id, trigger: event.date))
            changed = true
        }
        for dtc in old where !newCodes.contains(dtc.code) {
            guard await eventStore.lastKind(for: dtc.code) == .stored else { continue }
            await eventStore.record(DTCEvent(kind: .cleared, code: dtc.code, title: dtc.info.title))
            changed = true
        }
        if changed {
            history = await eventStore.all()
        }
    }

    /// Once a fault's post-window has elapsed, cut its slice out of the ring
    /// and attach it to the archived event.
    private func flushDueWindows() async {
        guard !pendingWindows.isEmpty else { return }
        let now = Date()
        var remaining: [(eventID: UUID, trigger: Date)] = []
        var changed = false
        for pending in pendingWindows {
            guard now.timeIntervalSince(pending.trigger) >= windowPost else {
                remaining.append(pending)
                continue
            }
            let start = pending.trigger.addingTimeInterval(-windowPre)
            let end = pending.trigger.addingTimeInterval(windowPost)
            let samples = ring
                .filter { $0.date >= start && $0.date <= end }
                .map {
                    WindowSample(
                        t: $0.date.timeIntervalSince(pending.trigger),
                        pid: String(format: "%02X", $0.pid),
                        value: $0.value
                    )
                }
            await eventStore.attachWindow(samples, toEventID: pending.eventID)
            changed = true
        }
        pendingWindows = remaining
        if changed {
            history = await eventStore.all()
        }
    }

    public func value(_ pid: PID) -> Double? {
        readings[pid.code]
    }
}
