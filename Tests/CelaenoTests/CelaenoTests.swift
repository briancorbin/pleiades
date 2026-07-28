import XCTest
@testable import Celaeno

final class DTCEventStoreTests: XCTestCase {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("celaeno-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testPersistsAcrossStoreInstances() async {
        let dir = scratchDirectory()
        let store = DTCEventStore(directory: dir)
        await store.record(DTCEvent(kind: .stored, code: "P0420", title: "Catalyst", freezeFrame: ["0C": 3100]))
        await store.record(DTCEvent(kind: .cleared, code: "P0420", title: "Catalyst"))

        let reloaded = DTCEventStore(directory: dir)
        let events = await reloaded.all()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.kind, .cleared)  // newest first
        XCTAssertEqual(events.last?.freezeFrame?["0C"], 3100)
    }

    func testLastKindTracksMostRecentEvent() async {
        let store = DTCEventStore(directory: scratchDirectory())
        let none = await store.lastKind(for: "P0420")
        XCTAssertNil(none)
        await store.record(DTCEvent(kind: .stored, code: "P0420", title: "Catalyst"))
        let stored = await store.lastKind(for: "P0420")
        XCTAssertEqual(stored, .stored)
        await store.record(DTCEvent(kind: .cleared, code: "P0420", title: "Catalyst"))
        let cleared = await store.lastKind(for: "P0420")
        XCTAssertEqual(cleared, .cleared)
    }
}

final class OccurrenceTests: XCTestCase {
    private func event(_ kind: DTCEvent.Kind, _ code: String, at seconds: TimeInterval) -> DTCEvent {
        DTCEvent(date: Date(timeIntervalSince1970: seconds), kind: kind, code: code, title: code)
    }

    func testStoredAndClearedPairIntoOneOccurrence() {
        let events = [
            event(.stored, "P0420", at: 100),
            event(.cleared, "P0420", at: 200),
        ]
        let occurrences = events.occurrences()
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences[0].clearedAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(occurrences[0].isActive)
    }

    func testRepeatedCyclesStaySeparateNewestFirst() {
        let events = [
            event(.stored, "P0420", at: 100),
            event(.cleared, "P0420", at: 200),
            event(.stored, "P0420", at: 300),
        ]
        let occurrences = events.occurrences()
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertTrue(occurrences[0].isActive)   // newest, un-cleared
        XCTAssertFalse(occurrences[1].isActive)  // the earlier cycle
    }

    func testClearedPairsWithItsOwnCodeOnly() {
        let events = [
            event(.stored, "P0420", at: 100),
            event(.stored, "P0301", at: 150),
            event(.cleared, "P0301", at: 200),
        ]
        let occurrences = events.occurrences()
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertTrue(occurrences.first { $0.code == "P0420" }!.isActive)
        XCTAssertFalse(occurrences.first { $0.code == "P0301" }!.isActive)
    }

    func testAttachWindowPersists() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("celaeno-window-\(UUID().uuidString)", isDirectory: true)
        let store = DTCEventStore(directory: dir)
        let event = DTCEvent(kind: .stored, code: "P0420", title: "Catalyst")
        await store.record(event)
        await store.attachWindow([WindowSample(t: -1, pid: "0C", value: 3000)], toEventID: event.id)

        let reloaded = DTCEventStore(directory: dir)
        let events = await reloaded.all()
        XCTAssertEqual(events.first?.window?.count, 1)
        XCTAssertEqual(events.first?.window?.first?.value, 3000)
        XCTAssertEqual(events.first?.window?.first?.t, -1)
    }
}

final class DriveStoreTests: XCTestCase {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("celaeno-drives-\(UUID().uuidString)", isDirectory: true)
    }

    func testRecordAndReloadSession() async {
        let dir = scratchDirectory()
        let store = DriveStore(directory: dir)
        await store.begin()
        await store.append([
            DriveSample(t: 0.1, pid: "0C", value: 650),
            DriveSample(t: 0.2, pid: "0C", value: 700),
        ])
        await store.append([DriveSample(t: 0.3, pid: "0D", value: 5)])
        let ended = await store.end()
        XCTAssertNotNil(ended?.endedAt)

        let reloaded = DriveStore(directory: dir)
        let sessions = await reloaded.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].samples.count, 3)
        XCTAssertEqual(sessions[0].samples.last?.pid, "0D")
    }

    func testListNewestFirstAndDelete() async {
        let dir = scratchDirectory()
        let store = DriveStore(directory: dir)
        let first = await store.begin()
        await store.end()
        try? await Task.sleep(for: .milliseconds(20))
        await store.begin()
        await store.end()

        var sessions = await store.list()
        XCTAssertEqual(sessions.count, 2)
        // ISO8601 persistence has whole-second resolution, so near-simultaneous
        // sessions can tie — newest-first just can't be ascending.
        XCTAssertTrue(sessions[0].startedAt >= sessions[1].startedAt)

        await store.delete(first.id)
        sessions = await store.list()
        XCTAssertEqual(sessions.count, 1)
    }

    func testAppendWithoutActiveSessionIsIgnored() async {
        let store = DriveStore(directory: scratchDirectory())
        await store.append([DriveSample(t: 0, pid: "0C", value: 1)])
        let sessions = await store.list()
        XCTAssertEqual(sessions.count, 0)
    }
}
