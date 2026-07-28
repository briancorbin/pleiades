import XCTest
@testable import Sterope
import Maia

final class SteropeEngineTests: XCTestCase {
    private let hotCoolant = AlertRule(
        id: "test.hot", pid: .coolantTemp, trigger: .above(100), clearMargin: 10,
        severity: .warning, message: "hot"
    )

    func testAboveRuleFires() {
        var engine = SteropeEngine(rules: [hotCoolant])
        let alerts = engine.evaluate([PID.coolantTemp.code: 101])
        XCTAssertEqual(alerts.map(\.id), ["test.hot"])
        XCTAssertEqual(alerts.first?.value, 101)
    }

    func testHysteresisHoldsUntilClearMargin() {
        var engine = SteropeEngine(rules: [hotCoolant])
        _ = engine.evaluate([PID.coolantTemp.code: 101])
        // Back under the limit but inside the margin: still firing.
        XCTAssertEqual(engine.evaluate([PID.coolantTemp.code: 95]).count, 1)
        // Past the margin: cleared.
        XCTAssertEqual(engine.evaluate([PID.coolantTemp.code: 89]).count, 0)
        // And it doesn't re-fire until the limit is crossed again.
        XCTAssertEqual(engine.evaluate([PID.coolantTemp.code: 95]).count, 0)
    }

    func testBelowRuleFires() {
        let lowFuel = AlertRule(
            id: "test.fuel", pid: .fuelLevel, trigger: .below(15), clearMargin: 3,
            severity: .critical, message: "fuel"
        )
        var engine = SteropeEngine(rules: [lowFuel])
        XCTAssertEqual(engine.evaluate([PID.fuelLevel.code: 14]).first?.severity, .critical)
        XCTAssertEqual(engine.evaluate([PID.fuelLevel.code: 16]).count, 1)  // inside margin
        XCTAssertEqual(engine.evaluate([PID.fuelLevel.code: 19]).count, 0)
    }

    func testMissingReadingDoesNotFire() {
        var engine = SteropeEngine(rules: [hotCoolant])
        XCTAssertEqual(engine.evaluate([:]).count, 0)
    }

    func testForesterDefaultsQuietOnHealthyCar() {
        var engine = SteropeEngine(rules: .foresterDefaults)
        let healthy: [UInt8: Double] = [
            PID.coolantTemp.code: 90, PID.oilTemp.code: 95,
            PID.controlModuleVoltage.code: 13.9, PID.rpm.code: 2200,
            PID.fuelLevel.code: 75,
        ]
        XCTAssertEqual(engine.evaluate(healthy).count, 0)
    }

    func testForesterDefaultsCatchOverheat() {
        var engine = SteropeEngine(rules: .foresterDefaults)
        let overheating: [UInt8: Double] = [PID.coolantTemp.code: 118]
        let alerts = engine.evaluate(overheating)
        XCTAssertEqual(alerts.count, 2)  // hot + overheat both fire
        XCTAssertTrue(alerts.contains { $0.severity == .critical })
    }
}
