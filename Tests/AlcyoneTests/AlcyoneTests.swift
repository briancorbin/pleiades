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

@MainActor
final class HistoryTests: XCTestCase {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alcyone-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testStoredEventArchivedWithFreezeFrame() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let model = TelemetryModel(source: source, historyDirectory: scratchDirectory())
        await model.poll(fast: true, slow: true)  // baseline, healthy

        await source.injectFault()
        await model.poll(fast: true, slow: true)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.kind, .stored)
        XCTAssertEqual(model.history.first?.code, "P0420")
        XCTAssertNotNil(model.history.first?.freezeFrame?["0C"])
        XCTAssertEqual(model.freezeDTC?.code, "P0420")
    }

    func testHistorySurvivesClearingCodes() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let model = TelemetryModel(source: source, historyDirectory: scratchDirectory())
        await source.injectFault()
        await model.poll(fast: true, slow: true)

        await model.clearDTCs()
        XCTAssertEqual(model.dtcs.count, 0)
        XCTAssertNil(model.freezeDTC)
        XCTAssertEqual(model.history.count, 2)  // stored + cleared, both kept
        XCTAssertEqual(model.history.first?.kind, .cleared)

        // Another poll must not duplicate anything.
        await model.poll(fast: true, slow: true)
        XCTAssertEqual(model.history.count, 2)
    }
}
