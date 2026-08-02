import XCTest
@testable import Maia

/// The registry is only worth having if it can't quietly go wrong.
///
/// It records what a platform exposes and how anybody knows;
/// `ProprietarySignal` records what the app actually asks for. Two statements
/// of one fact drift — silently, a line at a time, until nobody trusts either.
/// So they get compared, and changing one without the other fails the bench.
final class RegistryDriftTests: XCTestCase {
    private func registry() throws -> VehicleRegistry {
        try XCTUnwrap(VehicleRegistry.shared, "no registry bundled")
    }

    func testEveryVerifiedSignalInCodeIsConfirmedInTheRegistry() throws {
        let registry = try registry()
        for signal in ProprietarySignal.all where signal.verified {
            guard let found = registry.signal(signal.id) else {
                XCTFail("\(signal.name) is verified in code but absent from the registry")
                continue
            }
            XCTAssertEqual(
                found.signal.confidence, .confirmed,
                "\(signal.name) is verified in code but '\(found.signal.confidence.rawValue)' in the registry"
            )
            XCTAssertEqual(found.module.address, signal.module, "\(signal.name) disagrees about its module")
        }
    }

    func testNothingIsConfirmedWithoutBeingVerifiedInCode() throws {
        // The page-11 mirrors are measured but deliberately not polled — they
        // exist as a cross-check on their page-10 twins.
        let mirrors: Set<UInt16> = [0x1116, 0x1117]
        let verified = Set(ProprietarySignal.all.filter(\.verified).map(\.id))
        for module in try registry().modules {
            for signal in module.signals where signal.confidence == .confirmed {
                guard !mirrors.contains(signal.did) else { continue }
                XCTAssertTrue(
                    verified.contains(signal.did),
                    "\(signal.name) is confirmed in the registry but unverified in code"
                )
            }
        }
    }

    func testEncodingsAgreeBetweenRegistryAndCode() throws {
        // 0x75A says 00/FF, 0x788 says 01/02. Getting this wrong reports
        // every unfastened seatbelt as fastened.
        for module in try registry().modules {
            for signal in module.signals {
                guard let code = ProprietarySignal.all.first(where: { $0.id == signal.did }) else { continue }
                switch (signal.encoding, code.encoding) {
                case (.boolean(let registryTrue, _), .equals(let codeTrue)):
                    XCTAssertEqual(registryTrue, codeTrue, "\(signal.name) true-value disagrees")
                case (.boolean, .nonZero), (.raw, _), (.scaled, .scaled):
                    break // compatible
                default:
                    XCTFail("\(signal.name): registry \(signal.encoding) vs code \(code.encoding)")
                }
            }
        }
    }
}

/// The format's own rules, enforced rather than documented.
final class RegistryFormatTests: XCTestCase {
    private func registry() throws -> VehicleRegistry {
        try XCTUnwrap(VehicleRegistry.shared)
    }

    func testWriteAccessRequiresConfirmedConfidence() throws {
        // Reading a misidentified identifier costs a number you misinterpret.
        // Writing to one can misconfigure a restraint system on a stranger's
        // car. "I think this is a seatbelt" is not a good enough basis for 2E.
        for module in try registry().modules {
            for signal in module.signals where signal.access.write {
                XCTAssertEqual(
                    signal.confidence, .confirmed,
                    "\(module.label) \(signal.command) is writable at confidence '\(signal.confidence.rawValue)'"
                )
            }
        }
    }

    func testConfirmedSignalsCiteEvidence() throws {
        for module in try registry().modules {
            for signal in module.signals where signal.confidence == .confirmed {
                let observation = try XCTUnwrap(
                    signal.firstObservation, "\(signal.name) confirmed with no observation"
                )
                XCTAssertFalse(observation.by.isEmpty, "\(signal.name) has an observation with no contributor")
                XCTAssertNotNil(signal.evidence, "\(signal.name) is confirmed with no log file cited")
            }
        }
    }

    func testConfidenceIsDerivedNotAsserted() {
        func signal(_ observations: [VehicleRegistry.Observation]) -> VehicleRegistry.Signal {
            VehicleRegistry.Signal(
                did: 0x104E, name: "x", encoding: .raw,
                access: .init(read: true, write: false, securityAccess: nil),
                observations: observations, prediction: nil, note: nil
            )
        }
        func obs(_ by: String, reverted: Bool = false, rejected: Bool = false) -> VehicleRegistry.Observation {
            .init(by: by, vehicle: nil, date: "2026-07-30", method: nil, evidence: nil,
                  reverted: reverted, discriminated: [], rejected: rejected)
        }

        XCTAssertEqual(signal([]).confidence, .unidentified)
        XCTAssertEqual(signal([obs("a")]).confidence, .candidate)
        // Seen to change and change back — a measurement, not a correlation.
        XCTAssertEqual(signal([obs("a", reverted: true)]).confidence, .confirmed)
        // Or two people on two cars agreeing, which no other vehicle dataset
        // can express.
        XCTAssertEqual(signal([obs("a"), obs("b")]).confidence, .confirmed)
        // One person twice is still one person.
        XCTAssertEqual(signal([obs("a"), obs("a")]).confidence, .candidate)
        XCTAssertEqual(signal([obs("a", rejected: true)]).confidence, .rejected)
    }

    func testPredictionsNeverEarnConfidence() throws {
        // The three inferred doors: a prediction is not an observation.
        for module in try registry().modules {
            for signal in module.signals where signal.observations.isEmpty {
                XCTAssertEqual(signal.confidence, .unidentified, "\(signal.name) earned confidence without evidence")
                XCTAssertFalse(signal.access.write)
            }
        }
    }

    func testFingerprintIdentifiesThePlatform() throws {
        let registry = try registry()
        let full = Set(registry.platform.fingerprint)
        XCTAssertEqual(registry.matchScore(full), 1.0, accuracy: 0.001)
        XCTAssertEqual(VehicleRegistry.match(respondingModules: full)?.platform.id, registry.platform.id)

        // A car missing a couple of optional modules — no blind-spot radar,
        // say — must still match rather than fall off a cliff.
        var trimmed = full
        trimmed.remove(0x74A)
        trimmed.remove(0x74B)
        XCTAssertNotNil(VehicleRegistry.match(respondingModules: trimmed), "a trim level failed to match")

        // A completely different car must not.
        XCTAssertNil(VehicleRegistry.match(respondingModules: [0x7E8, 0x111, 0x222]))
    }

    func testOpenQuestionsAreActionable() throws {
        let questions = try registry().openQuestions
        XCTAssertFalse(questions.isEmpty)
        for question in questions {
            XCTAssertNotNil(
                question.howToAnswer,
                "\"\(question.question)\" has no way to answer it — that's a complaint, not a work item"
            )
        }
    }

    func testSignalsSortSoTheKnownOnesReadFirst() throws {
        for module in try registry().modules {
            let order = module.signals.map(\.confidence)
            XCTAssertEqual(order, order.sorted(), "\(module.label) signals are out of order")
        }
    }
}
