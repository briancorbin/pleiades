import Electra
import Maia

/// Where Alcyone's numbers come from. The dashboard never knows which one is
/// plugged in — that's the platform's one design rule.
public protocol TelemetrySource: Sendable {
    var session: ELM327Session { get }
    /// Called once per poll tick. Electra advances its fake clock here; a real
    /// adapter has nothing to do.
    func tick(dt: Double) async
}

/// The bench source: Electra's fake car behind its fake ELM327.
public final class ElectraSource: TelemetrySource, Sendable {
    public let car: ElectraCar
    public let session: ELM327Session

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
}
