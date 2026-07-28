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

    public let fastPIDs: [PID] = [.rpm, .speed, .throttle, .engineLoad]
    public let slowPIDs: [PID] = [
        .coolantTemp, .oilTemp, .controlModuleVoltage, .intakeAirTemp,
        .ambientAirTemp, .fuelLevel, .manifoldPressure, .timingAdvance,
        .runTime, .distanceWithMIL, .distanceSinceCleared,
    ]

    public let sourceLabel: String

    private let source: any TelemetrySource
    private var sterope: SteropeEngine
    private var loop: Task<Void, Never>?
    private var isInitialized = false

    public init(source: any TelemetrySource, rules: [AlertRule] = .foresterDefaults) {
        self.source = source
        self.sourceLabel = source.label
        self.sterope = SteropeEngine(rules: rules)
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
            dtcs = (try? await source.session.readDTCs()) ?? []
        }
        alerts = sterope.evaluate(readings)
    }

    /// Deliberate user action from the DTC row — clears codes and re-reads.
    public func clearDTCs() async {
        try? await source.session.clearDTCs()
        mil = try? await source.session.milStatus()
        dtcs = (try? await source.session.readDTCs()) ?? []
    }

    public func value(_ pid: PID) -> Double? {
        readings[pid.code]
    }
}
