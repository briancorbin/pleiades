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

final class StoredRuleTests: XCTestCase {
    func testConversionRoundTrip() {
        let stored = StoredRule(
            pidCode: PID.coolantTemp.code, kind: .above, limit: 105,
            clearMargin: 5, severity: .critical, message: "hot"
        )
        let rule = stored.alertRule()
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.pid, .coolantTemp)
        XCTAssertEqual(rule?.trigger, .above(105))
        XCTAssertEqual(rule?.severity, .critical)

        let back = StoredRule(from: rule!)
        XCTAssertEqual(back.pidCode, stored.pidCode)
        XCTAssertEqual(back.limit, 105)
        XCTAssertEqual(back.kind, .above)
    }

    func testDisabledRuleProducesNoAlertRule() {
        var stored = StoredRule(
            pidCode: PID.rpm.code, kind: .above, limit: 6000,
            clearMargin: 300, severity: .warning, message: "redline"
        )
        stored.enabled = false
        XCTAssertNil(stored.alertRule())
        XCTAssertEqual([stored].alertRules().count, 0)
    }

    func testUnknownPIDCodeProducesNoAlertRule() {
        let stored = StoredRule(
            pidCode: 0xEE, kind: .above, limit: 1,
            clearMargin: 0, severity: .warning, message: "ghost"
        )
        XCTAssertNil(stored.alertRule())
    }

    func testDefaultsMirrorForesterDefaults() {
        let defaults = StoredRule.defaults()
        XCTAssertEqual(defaults.count, [AlertRule].foresterDefaults.count)
        XCTAssertEqual(defaults.alertRules().count, defaults.count)
    }
}

final class RuleStoreTests: XCTestCase {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sterope-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testFirstLaunchSeedsDefaults() async {
        let store = RuleStore(directory: scratchDirectory())
        let rules = await store.all()
        XCTAssertEqual(rules.count, StoredRule.defaults().count)
    }

    func testSavePersistsAcrossInstances() async {
        let dir = scratchDirectory()
        let store = RuleStore(directory: dir)
        var rules = await store.all()
        rules[0].enabled = false
        rules.append(StoredRule(
            pidCode: PID.oilTemp.code, kind: .above, limit: 130,
            clearMargin: 5, severity: .critical, message: "custom"
        ))
        await store.save(rules)

        let reloaded = RuleStore(directory: dir)
        let loaded = await reloaded.all()
        XCTAssertEqual(loaded.count, StoredRule.defaults().count + 1)
        XCTAssertFalse(loaded[0].enabled)
        XCTAssertEqual(loaded.last?.message, "custom")
    }

    func testResetRestoresDefaults() async {
        let dir = scratchDirectory()
        let store = RuleStore(directory: dir)
        await store.save([])
        let reset = await store.resetToDefaults()
        XCTAssertEqual(reset.count, StoredRule.defaults().count)
        let reloaded = RuleStore(directory: dir)
        let loaded = await reloaded.all()
        XCTAssertEqual(loaded.count, StoredRule.defaults().count)
    }
}
