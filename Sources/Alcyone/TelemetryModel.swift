import Foundation
import Maia

/// Polls the session and publishes decoded readings for the views.
/// Fast PIDs refresh at 10 Hz, slow ones at 1 Hz.
@MainActor
public final class TelemetryModel: ObservableObject {
    @Published public private(set) var readings: [UInt8: Double] = [:]

    public let fastPIDs: [PID] = [.rpm, .speed, .throttle, .engineLoad]
    public let slowPIDs: [PID] = [
        .coolantTemp, .oilTemp, .controlModuleVoltage, .intakeAirTemp,
        .ambientAirTemp, .fuelLevel, .manifoldPressure, .timingAdvance,
    ]

    public let sourceLabel: String

    private let source: any TelemetrySource
    private var loop: Task<Void, Never>?
    private var isInitialized = false

    public init(source: any TelemetrySource) {
        self.source = source
        self.sourceLabel = source.label
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
    }

    public func value(_ pid: PID) -> Double? {
        readings[pid.code]
    }
}
