import XCTest
@testable import Alcyone
import Maia
import Sterope

@MainActor
final class TelemetryModelTests: XCTestCase {
    func testPollPopulatesReadingsFromElectra() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let model = TelemetryModel(source: source)
        await model.poll(fast: true, slow: true)
        let rpm = model.value(.rpm)
        XCTAssertNotNil(rpm)
        XCTAssertGreaterThan(rpm ?? 0, 0)
        XCTAssertNotNil(model.value(.coolantTemp))
        XCTAssertNotNil(model.value(.controlModuleVoltage))
    }

    func testFastPollSkipsSlowPIDs() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let model = TelemetryModel(source: source)
        await model.poll(fast: true, slow: false)
        XCTAssertNotNil(model.value(.rpm))
        XCTAssertNil(model.value(.coolantTemp))
    }

    func testInjectedFaultSurfacesInModel() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        await source.injectFault()
        let model = TelemetryModel(source: source)
        await model.poll(fast: true, slow: true)
        XCTAssertEqual(model.mil?.milOn, true)
        XCTAssertEqual(model.dtcs.map(\.code), ["P0420"])

        await model.clearDTCs()
        XCTAssertEqual(model.mil?.milOn, false)
        XCTAssertEqual(model.dtcs.count, 0)
    }

    func testSteropeAlertSurfacesInModel() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let redlineAt100 = AlertRule(
            id: "test.rpm", pid: .rpm, trigger: .above(100), clearMargin: 10,
            severity: .warning, message: "spinning"
        )
        let model = TelemetryModel(source: source, rules: [redlineAt100])
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(model.alerts.map(\.id), ["test.rpm"])
    }

    func testEngineOffStillReads() async {
        let source = ElectraSource()
        let model = TelemetryModel(source: source)
        await model.poll(fast: true, slow: true)
        XCTAssertEqual(model.value(.rpm), 0)
        XCTAssertEqual(model.value(.controlModuleVoltage) ?? 0, 12.4, accuracy: 0.01)
    }
}

final class UnitsTests: XCTestCase {
    func testMph() {
        XCTAssertEqual(Units.mph(100), 62.14, accuracy: 0.01)
    }

    func testFahrenheit() {
        XCTAssertEqual(Units.fahrenheit(90), 194)
        XCTAssertEqual(Units.fahrenheit(-40), -40)
    }
}
