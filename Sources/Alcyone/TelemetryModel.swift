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
    /// Proprietary signals — only present when the source is a CAN tap.
    /// A dongle simply never answers mode 22, so these stay empty.
    @Published public private(set) var proprietary: [UInt16: Double] = [:]
    @Published public private(set) var hasProprietary = false
    /// Consecutive unanswered reads per signal, and the ones we've given up
    /// on. Not published — this is bookkeeping, not something to render.
    private var misses: [UInt16: Int] = [:]
    private var silent: Set<UInt16> = []
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
    /// True once the adapter has actually answered its setup commands — not
    /// merely once we've tried. Published so the UI can say "connecting"
    /// instead of showing stale gauges as though they were live.
    @Published public private(set) var isInitialized = false
    private var storesLoaded = false

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

    /// Master switch for Alcyone's alert audio. Off means no alert makes a
    /// sound, whatever the individual rules say.
    @Published public var soundEnabled = true
    /// Scales every alert's own volume.
    @Published public var masterVolume: Double = 1.0

    private let soundPlayer: any AlertSoundPlaying

    public init(
        source: any TelemetrySource,
        rules: [AlertRule] = .foresterDefaults,
        ruleStore: RuleStore? = nil,
        historyDirectory: URL? = nil,
        drivesDirectory: URL? = nil,
        soundPlayer: (any AlertSoundPlaying)? = nil,
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
        #if canImport(AVFoundation)
        self.soundPlayer = soundPlayer ?? SystemAlertSoundPlayer()
        #else
        self.soundPlayer = soundPlayer ?? SilentSoundPlayer()
        #endif
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
        alerts = sterope.evaluate(allSignals())
        // No sound here: re-evaluating after an edit isn't a new event.
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
        // Local stores don't care whether a car is attached.
        if !storesLoaded {
            history = await eventStore.all()
            if let ruleStore {
                sterope = SteropeEngine(rules: await ruleStore.all().alertRules())
            }
            storesLoaded = true
        }

        // A dropped link means a new adapter session when it returns: an
        // ELM327 comes back with echo on and no protocol pinned, so whatever
        // we configured is gone. Re-run setup rather than talk to it as if
        // nothing happened.
        if isInitialized, !source.isReady {
            isInitialized = false
        }

        if !isInitialized {
            // The view calls connect() and start() back to back, but a BLE
            // dongle needs seconds to scan, connect and discover services.
            // Until it's ready every send fails instantly — and this used to
            // mark itself initialized anyway, leaving the adapter permanently
            // unconfigured while the UI sat there looking connected. That's
            // the "works sometimes" bug: a race with BLE.
            guard source.isReady else { return }
            do {
                try await source.session.initialize(
                    pinnedProtocol: source.pinnedProtocol,
                    receiveAllModules: source.receivesAllModules
                )
            } catch {
                return // stay uninitialized; the next tick tries again
            }
            resetSignalDiscovery()
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
            await pollProprietary()
            mil = try? await source.session.milStatus()
            let current = (try? await source.session.readDTCs()) ?? []
            await refreshFreezeFrame(hasCodes: !current.isEmpty)
            await recordTransitions(from: dtcs, to: current)
            dtcs = current
        }
        await flushDueWindows()
        alerts = sterope.evaluate(allSignals())
        playSounds(for: sterope.started)
    }

    /// PID readings and proprietary signals share one keyspace — PID codes
    /// below 0x100, proprietary above — so a rule can watch either.
    private func allSignals() -> [UInt16: Double] {
        var merged: [UInt16: Double] = [:]
        for (code, value) in readings {
            merged[UInt16(code)] = value
        }
        for (id, value) in proprietary {
            merged[id] = value
        }
        return merged
    }


    /// Sound plays on the rising edge only — once per event, not once per
    /// poll. Master switch and master volume gate every rule.
    private func playSounds(for started: [Alert]) {
        guard soundEnabled, masterVolume > 0 else { return }
        for alert in started where alert.sound != .silent {
            soundPlayer.play(alert.sound, volume: alert.volume * masterVolume)
        }
    }

    /// Preview a sound from the rule editor.
    public func preview(_ sound: AlertSound, volume: Double) {
        soundPlayer.play(sound, volume: volume * masterVolume)
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

    /// Proprietary signals ride the slow cadence — latches and tire
    /// pressures don't change at gauge rates.
    private func pollProprietary() async {
        // Headers on for the batch. A mode-22 request goes out functionally
        // and a dozen modules may answer; with headers off their replies
        // arrive anonymous and run together into nonsense. With headers on,
        // `readProprietary` can pick out the module that owns the signal.
        // Switched back afterwards because the PID parser has no idea what a
        // header is.
        // Restored inline at the end, not in a `defer` — a deferred Task
        // would send ATH0 whenever it got around to it, and the next PID poll
        // would meet a header it can't parse.
        _ = try? await source.session.send("ATH1")
        // Fixed timing for the batch. Adaptive timing tunes the wait from
        // observed response times, which is right for a PID one ECU answers
        // and wrong here: a body module is slower than the engine, and the
        // adapter would hang up before it got a word in.
        _ = try? await source.session.send("ATAT0")

        var found: [UInt16: Double] = [:]
        for signal in ProprietarySignal.all where !silent.contains(signal.id) {
            if let value = try? await source.session.readProprietary(signal) {
                found[signal.id] = value
                misses[signal.id] = 0
            } else {
                // Half the catalog is signals we haven't found on this car
                // yet. Asking for them forever costs a timeout each, every
                // cycle — so stop asking, and let a source change reset it.
                let count = (misses[signal.id] ?? 0) + 1
                misses[signal.id] = count
                if count >= 3 { silent.insert(signal.id) }
            }
        }
        _ = try? await source.session.send("ATAT1")
        _ = try? await source.session.send("ATH0")

        if !found.isEmpty {
            proprietary = found
            hasProprietary = true
        }
    }

    /// Enumerate a module for the Discover tab.
    ///
    /// Stops the poll loop for the duration: both would be issuing commands
    /// on one transport, and `BLEELMTransport` rejects overlapping sends
    /// rather than interleaving them.
    public func enumerate(
        module: UInt32, pages: [UInt8], passes: Int = 2, tag: String? = nil
    ) async throws -> DIDSnapshot {
        let wasRunning = loop != nil
        stop()
        defer { if wasRunning { start() } }

        if !isInitialized {
            guard source.isReady else { throw OBDError.connectionClosed }
            try await source.session.initialize(
                pinnedProtocol: source.pinnedProtocol,
                receiveAllModules: source.receivesAllModules
            )
            isInitialized = true
        }
        _ = try? await source.session.send("ATH1")
        defer { Task { _ = try? await self.source.session.send("ATH0") } }
        return try await source.session.enumerate(
            module: module, pages: pages, passes: passes, tag: tag
        )
    }

    /// Signals that have gone unanswered often enough to stop polling.
    /// Cleared whenever the source changes — a different car, or Merope
    /// instead of the dongle, has a different idea of what exists.
    public func resetSignalDiscovery() {
        misses.removeAll()
        silent.removeAll()
    }

    public func proprietaryValue(_ signal: ProprietarySignal) -> Double? {
        proprietary[signal.id]
    }

    /// True when the rear gate is open — the signal this whole project
    /// started over.
    public var gateOpen: Bool {
        (proprietary[ProprietarySignal.gate.id] ?? 0) > 0.5
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
