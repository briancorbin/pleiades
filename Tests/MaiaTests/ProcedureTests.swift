import XCTest
@testable import Maia

/// The procedures are the thing standing between a driveway trip and a
/// re-run of that driveway trip, so their definitions get checked the same
/// way the registry does.
final class ProcedureDefinitionTests: XCTestCase {
    private static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/capture-procedures.json")
    }

    private func procedures() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["procedures"] as? [[String: Any]])
    }

    func testProceduresParseAndAreNotEmpty() throws {
        let all = try procedures()
        XCTAssertFalse(all.isEmpty)
        for procedure in all {
            let id = (procedure["id"] as? String) ?? "?"
            let steps = (procedure["steps"] as? [[String: Any]]) ?? []
            XCTAssertFalse(steps.isEmpty, "procedure '\(id)' has no steps")
        }
    }

    func testEveryStepSaysWhatToDo() throws {
        for procedure in try procedures() {
            let id = (procedure["id"] as? String) ?? "?"
            for (index, step) in ((procedure["steps"] as? [[String: Any]]) ?? []).enumerated() {
                let action = step["do"] as? String
                XCTAssertNotNil(action, "\(id) step \(index + 1) doesn't say what to do")
                XCTAssertFalse((action ?? "").isEmpty)
                XCTAssertNotNil(step["expect"], "\(id) step \(index + 1) has no label")
            }
        }
    }

    func testStepsCanBeUndoneSoTheNextOneStartsClean() throws {
        // A step that changes the car without putting it back contaminates
        // every step after it. The only exception is an explicit baseline
        // step, which is a starting state rather than a change.
        for procedure in try procedures() {
            let id = (procedure["id"] as? String) ?? "?"
            for (index, step) in ((procedure["steps"] as? [[String: Any]]) ?? []).enumerated() {
                let isBaseline = (step["expect"] as? String) == "baseline"
                guard !isBaseline else { continue }
                XCTAssertNotNil(
                    step["undo"],
                    "\(id) step \(index + 1) has no revert — it would contaminate the steps after it"
                )
            }
        }
    }

    func testPredictedIdentifiersAreRealHex() throws {
        for procedure in try procedures() {
            for step in (procedure["steps"] as? [[String: Any]]) ?? [] {
                guard let candidate = step["candidate"] as? String else { continue }
                XCTAssertNotNil(
                    UInt16(candidate.replacingOccurrences(of: "0x", with: ""), radix: 16),
                    "'\(candidate)' isn't a hex identifier"
                )
            }
        }
    }

    func testProceduresTargetModulesWeKnowAbout() throws {
        for procedure in try procedures() {
            let id = (procedure["id"] as? String) ?? "?"
            let address = try XCTUnwrap(procedure["module"] as? String, "\(id) has no module")
            let module = UInt32(address.replacingOccurrences(of: "0x", with: ""), radix: 16)
            XCTAssertNotNil(module, "\(id) module '\(address)' isn't hex")
            // Diagnostic responses live in the 0x700-0x7FF window.
            XCTAssertTrue((0x700...0x7FF).contains(Int(module ?? 0)), "\(id) targets \(address)")
        }
    }

    func testTheDoorProcedureCoversEveryOpening() throws {
        let doors = try XCTUnwrap(try procedures().first { ($0["id"] as? String) == "doors" })
        let labels = ((doors["steps"] as? [[String: Any]]) ?? [])
            .compactMap { $0["expect"] as? String }
        // Four doors and the tailgate — the thing that was inferred rather
        // than measured, and the reason this procedure exists.
        XCTAssertEqual(labels.count, 5)
        XCTAssertTrue(labels.contains("Rear gate"))
    }

    func testTheBeltProcedureStartsFromAKnownBaseline() throws {
        // The original belt captures are stuck at 'candidate' because nobody
        // can say whether each belt stayed fastened as the next went on.
        // A leading "unfasten everything" step is what removes that doubt.
        let belts = try XCTUnwrap(try procedures().first { ($0["id"] as? String) == "belts" })
        let steps = try XCTUnwrap(belts["steps"] as? [[String: Any]])
        let first = try XCTUnwrap(steps.first?["do"] as? String)
        XCTAssertTrue(
            first.lowercased().contains("unfasten every"),
            "the belt procedure must start by clearing every buckle"
        )
        for step in steps.dropFirst() {
            let action = try XCTUnwrap(step["do"] as? String)
            XCTAssertTrue(
                action.contains("ONLY"),
                "'\(action)' doesn't isolate one belt — that's how the first attempt got ambiguous"
            )
        }
    }
}
