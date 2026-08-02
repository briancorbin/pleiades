import XCTest
@testable import Maia

/// The registry is only worth having if it can't quietly go wrong.
///
/// The bundled `signal-registry.json` records what this car exposes and how
/// we know it.
/// `ProprietarySignal.swift` records what the app actually asks for. Those are
/// two statements of the same fact, and two copies of a fact drift — silently,
/// one stale line at a time, until nobody trusts either.
///
/// So they get compared. Change the gate's identifier in one place and forget
/// the other, and this fails naming both.
final class RegistryDriftTests: XCTestCase {
    /// Located from this file rather than the working directory, so it works
    /// under `swift test` and from Xcode alike.
    private static var registryURL: URL {
        URL(fileURLWithPath: #filePath)          // Tests/MaiaTests/ThisFile.swift
            .deletingLastPathComponent()          // Tests/MaiaTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources/Maia/Resources/signal-registry.json")
    }

    private struct Entry {
        let did: UInt16
        let name: String
        let module: UInt32?
        let confidence: String
    }

    private func loadRegistry() throws -> [Entry] {
        let data = try Data(contentsOf: Self.registryURL)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "registry is not a JSON object"
        )
        let modules = try XCTUnwrap(root["modules"] as? [[String: Any]], "no modules array")

        return modules.flatMap { module -> [Entry] in
            let address = (module["address"] as? String).flatMap {
                UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16)
            }
            return ((module["signals"] as? [[String: Any]]) ?? []).compactMap { signal in
                guard let didText = signal["did"] as? String,
                      let did = UInt16(didText.replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { return nil }
                return Entry(
                    did: did,
                    name: (signal["name"] as? String) ?? "",
                    module: address,
                    confidence: (signal["confidence"] as? String) ?? ""
                )
            }
        }
    }

    func testRegistryIsPresentAndParses() throws {
        let entries = try loadRegistry()
        XCTAssertFalse(entries.isEmpty, "the registry lists no signals at all")
    }

    func testEveryVerifiedSignalInCodeIsRecordedAsConfirmed() throws {
        let registry = try loadRegistry()
        for signal in ProprietarySignal.all where signal.verified {
            guard let entry = registry.first(where: { $0.did == signal.id }) else {
                XCTFail("""
                \(signal.name) (\(String(format: "0x%04X", signal.id))) is marked verified in \
                ProprietarySignal.swift but is missing from the signal registry
                """)
                continue
            }
            XCTAssertEqual(
                entry.confidence, "confirmed",
                "\(signal.name) is verified in code but '\(entry.confidence)' in the registry"
            )
            XCTAssertEqual(
                entry.module, signal.module,
                "\(signal.name) disagrees about which module owns it"
            )
        }
    }

    func testNothingIsConfirmedInTheRegistryWithoutBeingVerifiedInCode() throws {
        // Except the page-11 mirrors, which are measured but deliberately not
        // polled — they exist as a cross-check on the page-10 signals.
        let mirrors: Set<UInt16> = [0x1116, 0x1117]
        let verified = Set(ProprietarySignal.all.filter(\.verified).map(\.id))

        for entry in try loadRegistry() where entry.confidence == "confirmed" {
            guard !mirrors.contains(entry.did) else { continue }
            XCTAssertTrue(
                verified.contains(entry.did),
                """
                \(entry.name) (\(String(format: "0x%04X", entry.did))) is confirmed in the registry \
                but not marked verified in ProprietarySignal.swift
                """
            )
        }
    }

    func testCandidatesInCodeAreNotClaimedAsConfirmed() throws {
        // The three unmeasured doors. If one gets promoted in code, the
        // registry has to gain the evidence at the same time.
        let registry = try loadRegistry()
        for signal in ProprietarySignal.all where !signal.verified {
            guard let entry = registry.first(where: { $0.did == signal.id }) else { continue }
            XCTAssertNotEqual(
                entry.confidence, "confirmed",
                "\(signal.name) is confirmed in the registry but unverified in code"
            )
        }
    }

    func testEveryConfirmedSignalCitesItsEvidence() throws {
        // A measurement with no log file behind it is a memory, not a record.
        let data = try Data(contentsOf: Self.registryURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modules = try XCTUnwrap(root["modules"] as? [[String: Any]])

        for module in modules {
            for signal in (module["signals"] as? [[String: Any]]) ?? [] {
                guard (signal["confidence"] as? String) == "confirmed" else { continue }
                let name = (signal["name"] as? String) ?? "?"
                XCTAssertEqual(
                    signal["provenance"] as? String, "measured",
                    "\(name) is confirmed but not marked as measured"
                )
                XCTAssertNotNil(signal["date"], "\(name) is confirmed with no date")
                XCTAssertNotNil(signal["evidence"], "\(name) is confirmed with no log file cited")
            }
        }
    }

    func testCandidatesSayHowToResolveThemselves() throws {
        let data = try Data(contentsOf: Self.registryURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modules = try XCTUnwrap(root["modules"] as? [[String: Any]])

        for module in modules {
            for signal in (module["signals"] as? [[String: Any]]) ?? [] {
                guard (signal["confidence"] as? String) == "candidate" else { continue }
                let name = (signal["name"] as? String) ?? "?"
                let hasPlan = signal["method"] != nil || signal["note"] != nil
                XCTAssertTrue(hasPlan, "\(name) is a candidate with no way to confirm or kill it")
            }
        }
    }

    func testOpenQuestionsAreActionable() throws {
        let data = try Data(contentsOf: Self.registryURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try XCTUnwrap(root["openQuestions"] as? [[String: Any]], "no open questions")

        XCTAssertFalse(questions.isEmpty)
        for question in questions {
            let text = (question["question"] as? String) ?? "?"
            XCTAssertNotNil(
                question["howToAnswer"],
                "\"\(text)\" is recorded with no way to answer it — that's a complaint, not a work item"
            )
        }
    }
}

/// The registry is now a type the app renders, not just a document — so the
/// parse has to hold up, not merely the file.
final class VehicleRegistryTests: XCTestCase {
    func testBundledRegistryLoads() throws {
        let registry = try XCTUnwrap(VehicleRegistry.shared, "registry missing from the bundle")
        XCTAssertFalse(registry.modules.isEmpty)
        XCTAssertEqual(registry.vehicle.year, 2022)
    }

    func testTheGateIsFindableByIdentifier() throws {
        let registry = try XCTUnwrap(VehicleRegistry.shared)
        let found = try XCTUnwrap(registry.signal(ProprietarySignal.gate.id))
        XCTAssertEqual(found.module.address, 0x75A)
        XCTAssertEqual(found.signal.confidence, .confirmed)
        XCTAssertTrue(found.signal.isPollable)
    }

    func testUnknownCountIsWhatIsLeftToFind() throws {
        let registry = try XCTUnwrap(VehicleRegistry.shared)
        // Identifiers that answer, minus the ones we've named. If this ever
        // goes negative the arithmetic is wrong somewhere.
        XCTAssertGreaterThan(registry.unknownCount, 0)
        XCTAssertLessThanOrEqual(registry.unknownCount, registry.totalAnswering)
    }

    func testSignalsSortByConfidenceSoTheKnownOnesReadFirst() throws {
        let registry = try XCTUnwrap(VehicleRegistry.shared)
        for module in registry.modules {
            let order = module.signals.map(\.confidence)
            XCTAssertEqual(order, order.sorted(), "\(module.label) signals are out of order")
        }
    }

    func testOnlyPollableSignalsClaimToBePollable() throws {
        let registry = try XCTUnwrap(VehicleRegistry.shared)
        let catalogue = Set(ProprietarySignal.all.map(\.id))
        for module in registry.modules {
            for signal in module.signals {
                XCTAssertEqual(signal.isPollable, catalogue.contains(signal.did), signal.name)
            }
        }
    }
}
