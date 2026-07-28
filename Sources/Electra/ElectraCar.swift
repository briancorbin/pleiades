import Foundation
import Maia

/// A plausible-physics 2022 Forester stand-in. Not a simulation of an FB25 —
/// just believable enough that gauges, thresholds, and log views built against
/// it behave sanely on the real car.
///
/// Time is injected via `advance(by:)`: tests are deterministic, and the CLI
/// demo advances in real time.
public actor ElectraCar {
    public struct Snapshot: Sendable {
        public var throttlePct: Double
        public var rpm: Double
        public var speedKmh: Double
        public var coolantC: Double
        public var oilTempC: Double
        public var intakeC: Double
        public var ambientC: Double
        public var voltage: Double
        public var loadPct: Double
        public var mapKPa: Double
        public var timingBTDC: Double
        public var mafGs: Double
        public var fuelPct: Double
        public var baroKPa: Double
        public var catTempC: Double
        public var fuelRateLh: Double
        public var runTimeS: Double
        public var distanceSinceClearKm: Double
        public var distanceWithMILKm: Double
    }

    private let ambientC: Double
    private var engineRunning = false
    private var throttlePct: Double = 0
    private var rpm: Double = 0
    private var speedKmh: Double = 0
    private var coolantC: Double
    private var oilTempC: Double
    private var fuelPct: Double = 75
    private var faults: [DTC] = []
    private var runTimeS: Double = 0
    private var distanceSinceClearKm: Double = 128
    private var distanceWithMILKm: Double = 0

    public init(ambientC: Double = 22) {
        self.ambientC = ambientC
        self.coolantC = ambientC
        self.oilTempC = ambientC
    }

    public func startEngine() {
        engineRunning = true
    }

    public func stopEngine() {
        engineRunning = false
        throttlePct = 0
    }

    /// Throttle position, 0–100.
    public func setThrottle(_ pct: Double) {
        throttlePct = min(max(pct, 0), 100)
    }

    /// Store a trouble code; the MIL lights while any are present.
    public func injectFault(_ dtc: DTC) {
        if !faults.contains(dtc) {
            faults.append(dtc)
        }
    }

    public func clearFaults() {
        faults = []
        distanceWithMILKm = 0
        distanceSinceClearKm = 0
    }

    public func currentFaults() -> [DTC] {
        faults
    }

    /// Step the model forward. Rates are tuned for feel, not fidelity:
    /// RPM responds in ~a second, speed in tens of seconds, coolant in minutes.
    public func advance(by dt: Double) {
        let throttle = throttlePct / 100

        if engineRunning {
            let targetRPM = 650 + throttle * 5350
            rpm.approach(targetRPM, rate: dt * 2)

            let targetSpeed = throttle * 180
            speedKmh.approach(targetSpeed, rate: dt * 0.05)

            coolantC.approach(90, rate: dt / 120)
            oilTempC.approach(coolantC + 5, rate: dt / 180)
            fuelPct = max(0, fuelPct - dt * (0.0005 + throttle * 0.002))
            runTimeS += dt
            let km = speedKmh * dt / 3600
            distanceSinceClearKm += km
            if !faults.isEmpty {
                distanceWithMILKm += km
            }
        } else {
            rpm.approach(0, rate: dt * 2)
            speedKmh.approach(0, rate: dt * 0.1)
            coolantC.approach(ambientC, rate: dt / 600)
            oilTempC.approach(ambientC, rate: dt / 600)
        }
    }

    public func snapshot() -> Snapshot {
        let throttle = throttlePct / 100
        let loadPct = engineRunning ? 15 + throttle * 75 : 0
        let mafGs = engineRunning ? 2 + (rpm / 1000) * (loadPct / 100) * 8 : 0
        let warm = coolantC > 60
        return Snapshot(
            throttlePct: throttlePct,
            rpm: rpm,
            speedKmh: speedKmh,
            coolantC: coolantC,
            oilTempC: oilTempC,
            intakeC: engineRunning ? ambientC + 5 : ambientC,
            ambientC: ambientC,
            voltage: engineRunning ? 13.9 : 12.4,
            loadPct: loadPct,
            mapKPa: engineRunning ? 25 + throttle * 76 : 101,
            timingBTDC: engineRunning ? 35 - throttle * 20 : 0,
            mafGs: mafGs,
            fuelPct: fuelPct,
            baroKPa: 101,
            catTempC: warm ? 450 + throttle * 250 : coolantC * 4,
            fuelRateLh: mafGs * 0.33,
            runTimeS: runTimeS,
            distanceSinceClearKm: distanceSinceClearKm,
            distanceWithMILKm: distanceWithMILKm
        )
    }
}

private extension Double {
    /// Move toward `target` by `rate` (fraction of the remaining gap, capped
    /// at arrival). First-order lag, cheap and stable at any step size.
    mutating func approach(_ target: Double, rate: Double) {
        self += (target - self) * min(rate, 1)
    }
}
