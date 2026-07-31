import Electra
import Maia

/// Where Alcyone's numbers come from. The dashboard never knows which one is
/// plugged in — that's the platform's one design rule.
public protocol TelemetrySource: Sendable {
    var session: ELM327Session { get }
    /// Shown in the dashboard header so it's always obvious whether the
    /// numbers are the real car or the bench.
    var label: String { get }
    /// Called once per poll tick. Electra advances its fake clock here; a real
    /// adapter has nothing to do.
    func tick(dt: Double) async
    /// ELM327 protocol number to pin at startup, skipping the adapter's slow
    /// automatic search. Nil lets it hunt.
    var pinnedProtocol: Int? { get }
    /// Whether the adapter needs its CAN receive filter widened to hear
    /// modules outside the OBD response window — true for a real ELM327,
    /// meaningless for a simulator that answers everything asked of it.
    var receivesAllModules: Bool { get }
    /// Whether the transport can carry a command yet.
    ///
    /// A simulated adapter always can. A BLE dongle has to scan, connect and
    /// discover services first — several seconds — and until then every send
    /// fails instantly rather than waiting.
    var isReady: Bool { get }
}

public extension TelemetrySource {
    /// A simulated adapter has no protocol to search for.
    var pinnedProtocol: Int? { nil }
    /// Nothing to wait for when the car is imaginary.
    var isReady: Bool { true }
    /// A simulated adapter has no filter to widen.
    var receivesAllModules: Bool { false }
}

/// The bench source: Electra's fake car behind its fake ELM327.
public final class ElectraSource: TelemetrySource, Sendable {
    public let car: ElectraCar
    public let session: ELM327Session
    public let label = "Electra · simulated car"

    public init(car: ElectraCar = ElectraCar()) {
        self.car = car
        self.session = ELM327Session(transport: ELM327Emulator(car: car))
    }

    public func tick(dt: Double) async {
        await car.advance(by: dt)
    }

    // Bench controls, surfaced in the dashboard only when driving Electra.

    public func setEngine(on: Bool) async {
        on ? await car.startEngine() : await car.stopEngine()
    }

    public func setThrottle(_ pct: Double) async {
        await car.setThrottle(pct)
    }

    /// Cycles through a few classic Subaru codes so the check-engine flow is
    /// demonstrable from the bench bar.
    public func injectFault() async {
        let classics = ["P0420", "P0301", "P0128"]
        let next = classics[await car.currentFaults().count % classics.count]
        if let dtc = DTC(next) {
            await car.injectFault(dtc)
        }
    }
}
