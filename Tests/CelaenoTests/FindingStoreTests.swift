import XCTest
@testable import Celaeno

/// Findings are made in a driveway and have to survive the trip home.
final class FindingStoreTests: XCTestCase {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("findings-\(UUID().uuidString)", isDirectory: true)
    }

    func testAFindingSurvivesAReload() async {
        let dir = scratch()
        let store = FindingStore(directory: dir)
        await store.record(Finding(did: 0x104E, module: 0x75A, name: "Rear gate"))

        let reopened = FindingStore(directory: dir)
        let all = await reopened.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Rear gate")
    }

    func testRenamingReplacesRatherThanStacks() async {
        let store = FindingStore(directory: scratch())
        await store.record(Finding(did: 0x104E, module: 0x75A, name: "Something"))
        await store.record(Finding(did: 0x104E, module: 0x75A, name: "Rear gate"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1, "a second opinion stacked instead of replacing")
        XCTAssertEqual(all.first?.name, "Rear gate")
    }

    func testConfidenceReflectsWhetherItWasSeenBothWays() {
        // Moving once is a correlation; moving and returning is a measurement.
        let once = Finding(did: 1, module: 0x75A, name: "x", reverted: false)
        let both = Finding(did: 2, module: 0x75A, name: "y", reverted: true)
        XCTAssertEqual(once.confidence, "unidentified")
        XCTAssertEqual(both.confidence, "candidate")
    }

    func testExportNamesTheIdentifierAndItsEvidence() async {
        let store = FindingStore(directory: scratch())
        await store.record(Finding(
            did: 0x104E, module: 0x75A, name: "Rear gate",
            observedIn: ["gate closed", "gate open"],
            before: "00", after: "FF"
        ))
        let patch = await store.exportPatch()
        XCTAssertTrue(patch.contains("22 104E"), patch)
        XCTAssertTrue(patch.contains("Rear gate"))
        XCTAssertTrue(patch.contains("00 → FF"))
        XCTAssertTrue(patch.contains("gate closed → gate open"))
    }

    func testEmptyExportSaysSoRatherThanLookingBroken() async {
        let store = FindingStore(directory: scratch())
        let patch = await store.exportPatch()
        XCTAssertTrue(patch.contains("nothing recorded yet"))
    }
}
