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
