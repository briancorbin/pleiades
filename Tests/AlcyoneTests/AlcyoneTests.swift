import XCTest
@testable import Alcyone
import Maia

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
