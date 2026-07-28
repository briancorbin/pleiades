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

    public init(
        source: any TelemetrySource,
        rules: [AlertRule] = .foresterDefaults,
        historyDirectory: URL? = nil
    ) {
        self.source = source
        self.sourceLabel = source.label
        self.sterope = SteropeEngine(rules: rules)
        self.eventStore = DTCEventStore(directory: historyDirectory)
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
            isInitialized = true
        }
        await source.tick(dt: 0.1)
        var pids: [PID] = fast ? fastPIDs : []
        if slow { pids += slowPIDs }
        for pid in pids {
            if let reading = try? await source.session.read(pid) {
                readings[pid.code] = reading.value
            }
        }
        if slow {
            mil = try? await source.session.milStatus()
            let current = (try? await source.session.readDTCs()) ?? []
            await refreshFreezeFrame(hasCodes: !current.isEmpty)
            await recordTransitions(from: dtcs, to: current)
            dtcs = current
        }
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
            await eventStore.record(DTCEvent(kind: .stored, code: dtc.code, title: dtc.info.title, freezeFrame: frame))
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

    public func value(_ pid: PID) -> Double? {
        readings[pid.code]
    }
}
