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
