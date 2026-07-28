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

@MainActor
final class WindowCaptureTests: XCTestCase {
    func testFaultEventGainsTelemetryWindow() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alcyone-window-\(UUID().uuidString)", isDirectory: true)
        // Post-window of 0 so the window flushes on the same poll that
        // detects the fault; pre-window comfortably covers the test run.
        let model = TelemetryModel(source: source, historyDirectory: dir, windowPre: 60, windowPost: 0)

        await source.setThrottle(50)
        for _ in 0..<5 {
            await source.car.advance(by: 1)
            await model.poll(fast: true, slow: false)  // fill the ring
        }
        await source.injectFault()
        await model.poll(fast: true, slow: true)

        let occurrence = model.history.occurrences().first
        XCTAssertNotNil(occurrence)
        XCTAssertTrue(occurrence!.isActive)
        let window = occurrence?.window ?? []
        XCTAssertFalse(window.isEmpty)
        XCTAssertTrue(window.contains { $0.pid == "0C" })      // rpm in the movie
        XCTAssertTrue(window.allSatisfy { $0.t <= 0.5 })       // pre-trigger data
    }
}

@MainActor
final class RuleSwappingTests: XCTestCase {
    func testSetRulesAppliesImmediately() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let sensitive = AlertRule(
            id: "test.rpm", pid: .rpm, trigger: .above(100), clearMargin: 10,
            severity: .warning, message: "spinning"
        )
        let model = TelemetryModel(source: source, rules: [sensitive])
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(model.alerts.count, 1)

        model.setRules([])
        XCTAssertEqual(model.alerts.count, 0)
    }

    func testRuleStoreDrivesEngineAtStartup() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alcyone-rules-\(UUID().uuidString)", isDirectory: true)
        let store = RuleStore(directory: dir)
        await store.save([StoredRule(
            id: "custom.rpm", pidCode: PID.rpm.code, kind: .above, limit: 100,
            clearMargin: 10, severity: .warning, message: "custom store rule"
        )])

        let source = ElectraSource()
        await source.setEngine(on: true)
        let model = TelemetryModel(source: source, rules: [], ruleStore: store)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(model.alerts.map(\.id), ["custom.rpm"])
    }
}

@MainActor
final class DriveRecordingTests: XCTestCase {
    func testRecordingCapturesPollsAndSurvivesStop() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alcyone-drives-\(UUID().uuidString)", isDirectory: true)
        // Flush interval 0 → every poll writes through, no waiting in tests.
        let model = TelemetryModel(source: source, drivesDirectory: dir, driveFlushInterval: 0)

        await model.startRecording()
        XCTAssertTrue(model.isRecording)
        for _ in 0..<3 {
            await source.car.advance(by: 1)
            await model.poll(fast: true, slow: false)
        }
        await model.stopRecording()
        XCTAssertFalse(model.isRecording)

        let sessions = await model.driveStore.list()
        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertNotNil(session.endedAt)
        XCTAssertTrue(session.samples.contains { $0.pid == "0C" })  // rpm logged
        XCTAssertGreaterThanOrEqual(session.samples.count, 12)      // 3 polls × 4 fast PIDs
    }

    func testNotRecordingLogsNothing() async {
        let source = ElectraSource()
        await source.setEngine(on: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alcyone-drives-\(UUID().uuidString)", isDirectory: true)
        let model = TelemetryModel(source: source, drivesDirectory: dir)
        await model.poll(fast: true, slow: true)
        let sessions = await model.driveStore.list()
        XCTAssertEqual(sessions.count, 0)
    }
}

@MainActor
final class AlertSoundTests: XCTestCase {
    private func model(_ player: SilentSoundPlayer, rules: [AlertRule]) -> (TelemetryModel, ElectraSource) {
        let source = ElectraSource()
        return (TelemetryModel(source: source, rules: rules, soundPlayer: player), source)
    }

    private var loudRule: AlertRule {
        AlertRule(
            id: "test.rpm", pid: .rpm, trigger: .above(100), clearMargin: 10,
            severity: .warning, message: "spinning",
            sound: .builtIn("alert"), volume: 0.5
        )
    }

    func testSoundPlaysOnceOnRisingEdge() async {
        let player = SilentSoundPlayer()
        let (model, source) = model(player, rules: [loudRule])
        await source.setEngine(on: true)

        await model.poll(fast: true, slow: false)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(player.played.first?.sound, .builtIn("alert"))

        // Still firing on later polls — must not re-play.
        await model.poll(fast: true, slow: false)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(player.played.count, 1)
    }

    func testSoundReplaysAfterAlertClearsAndReturns() async {
        let player = SilentSoundPlayer()
        let (model, source) = model(player, rules: [loudRule])
        await source.setEngine(on: true)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(player.played.count, 1)

        await source.setEngine(on: false)
        for _ in 0..<5 {
            await source.car.advance(by: 1)
            await model.poll(fast: true, slow: false)
        }
        await source.setEngine(on: true)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(player.played.count, 2)
    }

    func testMasterSwitchSilencesEverything() async {
        let player = SilentSoundPlayer()
        let (model, source) = model(player, rules: [loudRule])
        model.soundEnabled = false
        await source.setEngine(on: true)
        await model.poll(fast: true, slow: false)
        XCTAssertTrue(model.alerts.count > 0)   // still alerts visually
        XCTAssertEqual(player.played.count, 0)  // just silently
    }

    func testMasterVolumeScalesRuleVolume() async {
        let player = SilentSoundPlayer()
        let (model, source) = model(player, rules: [loudRule])
        model.masterVolume = 0.5
        await source.setEngine(on: true)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(player.played.first?.volume ?? 0, 0.25, accuracy: 0.001)
    }

    func testSilentRuleMakesNoSound() async {
        let silent = AlertRule(
            id: "test.quiet", pid: .rpm, trigger: .above(100), clearMargin: 10,
            severity: .warning, message: "quiet", sound: .silent
        )
        let player = SilentSoundPlayer()
        let (model, source) = model(player, rules: [silent])
        await source.setEngine(on: true)
        await model.poll(fast: true, slow: false)
        XCTAssertEqual(model.alerts.count, 1)
        XCTAssertEqual(player.played.count, 0)
    }
}
