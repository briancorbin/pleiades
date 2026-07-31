import XCTest
@testable import Maia

/// The scanner runs once, in a driveway, with a tailgate held open. Every
/// parsing decision it makes has to be settled here first.
final class DIDFrameParsingTests: XCTestCase {
    func testParsesCompactElevenBitFrame() {
        // ATS0: header and payload collapse into one odd-length hex run.
        let frames = DIDScan.frames(in: "7E8046201005A\r")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.header, 0x7E8)
        XCTAssertEqual(frames.first?.bytes, [0x04, 0x62, 0x01, 0x00, 0x5A])
    }

    func testParsesSpacedFrame() {
        let frames = DIDScan.frames(in: "7E8 04 62 01 00 5A\r")
        XCTAssertEqual(frames.first?.header, 0x7E8)
        XCTAssertEqual(frames.first?.bytes, [0x04, 0x62, 0x01, 0x00, 0x5A])
    }

    func testParsesTwentyNineBitHeaderByParity() {
        // An even-length run means an 8-char header; nothing else fits.
        let frames = DIDScan.frames(in: "18DAF110036201\r")
        XCTAssertEqual(frames.first?.header, 0x18DAF110)
        XCTAssertEqual(frames.first?.bytes, [0x03, 0x62, 0x01])
    }

    func testSeparatesMultipleResponders() {
        let raw = "7E8046201005A\r7E9046201000F\r71F04620100FF\r"
        XCTAssertEqual(DIDScan.frames(in: raw).map(\.header), [0x7E8, 0x7E9, 0x71F])
    }

    func testIgnoresChromeAndBlankLines() {
        let raw = "SEARCHING...\r\r7E8046201005A\r\rOK\r"
        XCTAssertEqual(DIDScan.frames(in: raw).count, 1)
    }

    func testRejectsNonHex() {
        XCTAssertTrue(DIDScan.frames(in: "NO DATA\r").isEmpty)
        XCTAssertTrue(DIDScan.frames(in: "CAN ERROR\r").isEmpty)
    }
}

final class DIDReassemblyTests: XCTestCase {
    func testSingleFrameHonorsItsLengthByte() {
        // The last byte is CAN padding, not payload — the PCI says 4.
        let messages = DIDScan.messages(in: "7E80462010012AA\r")
        XCTAssertEqual(messages.first?.bytes, [0x62, 0x01, 0x00, 0x12])
    }

    func testReassemblesMultiFrame() {
        // First frame declares 10 bytes and carries 6; the consecutive frame
        // brings the last 4.
        let raw = """
        7E8100A620101020304
        7E82105060708
        """
        let messages = DIDScan.messages(in: raw)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(
            messages.first?.bytes,
            [0x62, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        )
    }

    func testInterleavedMultiFrameFromTwoModules() {
        // Two modules answering at once is the normal case on this car, and
        // their consecutive frames arrive interleaved.
        let raw = """
        7E81008620102030405
        7E91008620112131415
        7E8210607
        7E9211617
        """
        let messages = DIDScan.messages(in: raw)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first(where: { $0.module == 0x7E8 })?.bytes.last, 0x07)
        XCTAssertEqual(messages.first(where: { $0.module == 0x7E9 })?.bytes.last, 0x17)
    }

    func testDoesNotConcatenateTwoSingleFramesFromOneModule() {
        // responsePending then the real answer: two messages, not one blob.
        let messages = DIDScan.messages(in: "7E8037F2278\r7E80462010012\r")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].bytes, [0x7F, 0x22, 0x78])
        XCTAssertEqual(messages[1].bytes, [0x62, 0x01, 0x00, 0x12])
    }
}

final class DIDReplyTests: XCTestCase {
    func testPositiveReply() {
        let replies = DIDScan.replies(to: 0x0100, in: "7E8056201001234\r")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].module, 0x7E8)
        XCTAssertEqual(replies[0].data, [0x12, 0x34])
        XCTAssertTrue(replies[0].isPositive)
    }

    func testNegativeReplyKeepsItsCode() {
        let replies = DIDScan.replies(to: 0x0100, in: "7E8037F2231\r")
        XCTAssertEqual(replies[0].negativeCode, 0x31)
        XCTAssertFalse(replies[0].isPositive)
        XCTAssertEqual(UDSNegativeCode.name(0x31), "requestOutOfRange")
    }

    func testDropsResponsePendingWhenTheAnswerFollows() {
        let replies = DIDScan.replies(to: 0x0100, in: "7E8037F2278\r7E80462010012\r")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].data, [0x12])
    }

    func testKeepsResponsePendingWhenNothingFollows() {
        let replies = DIDScan.replies(to: 0x0100, in: "7E8037F2278\r")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].negativeCode, 0x78)
    }

    func testIgnoresAnswersToADifferentIdentifier() {
        // A late reply to the previous request must not be filed under this one.
        XCTAssertTrue(DIDScan.replies(to: 0x0100, in: "7E80462010912\r").isEmpty)
    }

    func testSilenceIsNotAnError() {
        XCTAssertTrue(DIDScan.replies(to: 0x0100, in: "NO DATA\r\r").isEmpty)
    }
}

/// Replayed from `logs/recon-20260730-180734.log` — the frames Merope
/// actually heard on the car when the app asked for identifier 0x0100.
/// Fourteen body modules answered alongside the ECM; the dongle's receive
/// filter discarded all fourteen, which is why the first sweep found nothing.
/// If a change to the parser ever drops these again, this fails.
final class RealCarReplyTests: XCTestCase {
    private let capture = """
    7E8 07 62 01 00 F7 C1 7F D1
    78F 07 62 01 00 00 01 EB D1
    77E 07 62 01 00 00 01 E9 C1
    7B8 07 62 01 00 00 01 E9 51
    71F 07 62 01 00 00 01 E9 51
    74A 07 62 01 00 00 00 E0 50
    78B 07 62 01 00 00 00 00 00
    788 07 62 01 00 00 01 EB 51
    78E 07 62 01 00 FF C1 FF F1
    7BC 07 62 01 00 00 01 F9 D1
    7C9 07 62 01 00 00 01 F9 D1
    74B 07 62 01 00 00 00 E0 50
    75B 07 62 01 00 00 00 E1 41
    75A 07 62 01 00 00 01 F9 51
    7DD 07 62 01 00 00 01 F9 51
    """

    func testEveryModuleIsHeardSeparately() {
        let replies = DIDScan.replies(to: 0x0100, in: capture)
        XCTAssertEqual(replies.count, 15)
        XCTAssertEqual(Set(replies.map(\.module)).count, 15)
        XCTAssertTrue(replies.allSatisfy(\.isPositive))
    }

    func testModulesAnsweringTheSameIdentifierKeepTheirOwnData() {
        let replies = DIDScan.replies(to: 0x0100, in: capture)
        func data(_ module: UInt32) -> [UInt8]? { replies.first { $0.module == module }?.data }
        // The engine and the body modules disagree about 0x0100 — which is
        // the entire point of keeping the header.
        XCTAssertEqual(data(0x7E8), [0xF7, 0xC1, 0x7F, 0xD1])
        XCTAssertEqual(data(0x74A), [0x00, 0x00, 0xE0, 0x50])
        XCTAssertEqual(data(0x78E), [0xFF, 0xC1, 0xFF, 0xF1])
    }

    func testTrailingPaddingIsNotMistakenForPayload() {
        // 78B answers all zeros; the PCI still says 7 bytes, so the payload
        // is four zeros and not an empty reply.
        let replies = DIDScan.replies(to: 0x0100, in: capture)
        XCTAssertEqual(replies.first { $0.module == 0x78B }?.data, [0x00, 0x00, 0x00, 0x00])
    }
}

/// The car volunteers its own map. Every case here is measured, not invented —
/// masks and the identifiers they predicted, from `logs/did-20260730-184939`.
final class SupportBitmaskTests: XCTestCase {
    func testBodyModuleMaskPredictsExactlyWhatItAnswered() {
        // 74A answered 00 00 E0 50 for base 0100, then answered these five
        // and nothing else.
        let supported = DIDScan.supportedIdentifiers(mask: [0x00, 0x00, 0xE0, 0x50], base: 0x0100)
        XCTAssertEqual(supported, [0x0111, 0x0112, 0x0113, 0x011A, 0x011C])
    }

    func testRicherModuleMask() {
        // 7DD answered 00 01 F9 51.
        let supported = DIDScan.supportedIdentifiers(mask: [0x00, 0x01, 0xF9, 0x51], base: 0x0100)
        XCTAssertEqual(
            supported,
            [0x0110, 0x0111, 0x0112, 0x0113, 0x0114, 0x0115, 0x0118, 0x011A, 0x011C, 0x0120]
        )
    }

    func testChainBitPicksOutTheTwoModulesThatHadAnotherBlock() {
        // 78F and 7DD answered 01 00 00 01 at 0120 and were the only two to
        // answer 0140. Everyone else answered 01 00 00 00 and stopped.
        XCTAssertTrue(DIDScan.chainsToNextBlock(mask: [0x01, 0x00, 0x00, 0x01]))
        XCTAssertFalse(DIDScan.chainsToNextBlock(mask: [0x01, 0x00, 0x00, 0x00]))
        XCTAssertFalse(DIDScan.chainsToNextBlock(mask: [0x09, 0x00, 0x00, 0x00]))
    }

    func testEmptyMaskSupportsNothing() {
        XCTAssertTrue(DIDScan.supportedIdentifiers(mask: [0, 0, 0, 0], base: 0x0100).isEmpty)
        XCTAssertFalse(DIDScan.chainsToNextBlock(mask: [0, 0, 0, 0]))
    }

    func testShortMaskDoesNotOverrun() {
        XCTAssertEqual(DIDScan.supportedIdentifiers(mask: [0x80], base: 0x0100), [0x0101])
        XCTAssertFalse(DIDScan.chainsToNextBlock(mask: [0x80]))
    }
}

final class DIDSnapshotTests: XCTestCase {
    private func reply(_ module: UInt32, _ did: UInt16, _ data: [UInt8]?) -> DIDReply {
        DIDReply(module: module, did: did, data: data, negativeCode: data == nil ? 0x31 : nil)
    }

    func testMergeFlagsValuesThatMovedBetweenPasses() {
        let snapshot = DIDSnapshot.merge(
            passes: [
                [reply(0x7E8, 0x0100, [0x01]), reply(0x7E8, 0x0101, [0x10])],
                [reply(0x7E8, 0x0100, [0x01]), reply(0x7E8, 0x0101, [0x11])],
            ],
            tag: "idle",
            firstDID: 0x0100,
            lastDID: 0x0101,
            capturedAt: Date()
        )
        XCTAssertEqual(snapshot.replies.count, 2)
        XCTAssertFalse(snapshot.replies[0].volatile)
        XCTAssertTrue(snapshot.replies[1].volatile)
        XCTAssertEqual(snapshot.passes, 2)
    }

    func testMergeKeepsTheFirstPassValue() {
        let snapshot = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0xAA])], [reply(0x7E8, 0x0100, [0xBB])]],
            tag: nil, firstDID: 0x0100, lastDID: 0x0100, capturedAt: Date()
        )
        XCTAssertEqual(snapshot.replies[0].data, [0xAA])
    }

    func testDiffFindsTheChangedIdentifier() {
        let before = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x00, 0x00]), reply(0x7E8, 0x0101, [0xFF])]],
            tag: "gate closed", firstDID: 0x0100, lastDID: 0x0101, capturedAt: Date()
        )
        let after = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x00, 0x01]), reply(0x7E8, 0x0101, [0xFF])]],
            tag: "gate open", firstDID: 0x0100, lastDID: 0x0101, capturedAt: Date()
        )
        let deltas = DIDScan.diff(from: before, to: after)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].did, 0x0100)
        XCTAssertEqual(deltas[0].kind, .changed)
        XCTAssertEqual(deltas[0].changedByteIndices, [1])
    }

    func testDiffHidesVolatileIdentifiersUnlessAsked() {
        // A counter that ticks on its own can't be evidence about the gate.
        let before = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x01])], [reply(0x7E8, 0x0100, [0x02])]],
            tag: "closed", firstDID: 0x0100, lastDID: 0x0100, capturedAt: Date()
        )
        let after = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x09])], [reply(0x7E8, 0x0100, [0x0A])]],
            tag: "open", firstDID: 0x0100, lastDID: 0x0100, capturedAt: Date()
        )
        XCTAssertTrue(DIDScan.diff(from: before, to: after).isEmpty)
        XCTAssertEqual(DIDScan.diff(from: before, to: after, includeVolatile: true).count, 1)
    }

    func testDiffClassifiesAppearAndVanish() {
        let before = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, nil), reply(0x7E8, 0x0101, [0x05])]],
            tag: nil, firstDID: 0x0100, lastDID: 0x0101, capturedAt: Date()
        )
        let after = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x07]), reply(0x7E8, 0x0101, nil)]],
            tag: nil, firstDID: 0x0100, lastDID: 0x0101, capturedAt: Date()
        )
        let deltas = DIDScan.diff(from: before, to: after)
        XCTAssertEqual(deltas.map(\.kind), [.appeared, .vanished])
    }

    func testDiffIgnoresIdenticalSweeps() {
        let sweep = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0100, [0x01, 0x02, 0x03])]],
            tag: nil, firstDID: 0x0100, lastDID: 0x0100, capturedAt: Date()
        )
        XCTAssertTrue(DIDScan.diff(from: sweep, to: sweep).isEmpty)
    }

    func testLengthChangeMarksTheTrailingBytes() {
        let delta = DIDDelta(
            module: 0x7E8, did: 0x0100, kind: .changed,
            before: [0x01], after: [0x01, 0x02], volatile: false
        )
        XCTAssertEqual(delta.changedByteIndices, [1])
    }

    func testSnapshotSurvivesAJSONRoundTrip() throws {
        let original = DIDSnapshot.merge(
            passes: [
                [reply(0x7E8, 0x0100, [0xDE, 0xAD]), reply(0x71F, 0x0101, nil)],
                [reply(0x7E8, 0x0100, [0xBE, 0xEF]), reply(0x71F, 0x0101, nil)],
            ],
            tag: "gate open",
            firstDID: 0x0100,
            lastDID: 0x0101,
            capturedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let restored = try DIDSnapshot(json: original.encoded())
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.tag, "gate open")
        XCTAssertTrue(restored.replies.first { $0.did == 0x0100 }?.volatile ?? false)
    }

    func testSnapshotJSONIsReadableHex() throws {
        let snapshot = DIDSnapshot.merge(
            passes: [[reply(0x7E8, 0x0142, [0x0A, 0xFF])]],
            tag: nil, firstDID: 0x0100, lastDID: 0x01FF,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let text = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"7E8\""), text)
        XCTAssertTrue(text.contains("\"0142\""), text)
        XCTAssertTrue(text.contains("\"0A FF\""), text)
    }
}

/// The measurement this whole project was built to make.
///
/// Module 75A ("Integ. Unit") enumerated three times — tailgate shut,
/// tailgate open, passenger door open — from
/// `logs/did-2026073019{0933,1135,1652}`. Five identifiers moved, and the
/// third state is what tells them apart:
///
/// ```
/// DID     gate closed   gate open   psgr door
/// 104B    00            00          FF          front passenger door
/// 104E    00            FF          00          THE REAR GATE
/// 1073    00            FF          FF          any opening
/// 1116    00            00          FF          passenger door (page 11)
/// 1117    00            FF          00          rear gate (page 11)
/// ```
final class MeasuredSignalTests: XCTestCase {
    func testGateIsTheIdentifierThatMovedForTheGateAlone() {
        XCTAssertEqual(ProprietarySignal.gate.id, 0x104E)
        XCTAssertEqual(ProprietarySignal.gate.module, 0x75A)
        XCTAssertTrue(ProprietarySignal.gate.verified)
        XCTAssertEqual(ProprietarySignal.gate.command, "22104E")
    }

    func testTheCarAnswersFFForTrueNotOne() {
        // 00 -> FF, never 00 -> 01. A decoder testing `== 1` would read every
        // open tailgate as closed.
        XCTAssertEqual(ProprietarySignal.gate.decode([0xFF]), 1)
        XCTAssertEqual(ProprietarySignal.gate.decode([0x00]), 0)
    }

    func testMeropesTwoByteEncodingStillDecodes() {
        // The bench sends a scaled uint16; the car sends one byte. Both work.
        XCTAssertEqual(ProprietarySignal.gate.decode([0x00, 0x01]), 1)
        // 0x08CA = 2250, one decimal place -> 225.0 kPa, about 32.6 psi.
        XCTAssertEqual(ProprietarySignal.tpmsFrontLeft.decode([0x08, 0xCA]), 225.0, accuracy: 0.01)
    }

    func testVerifiedSetIsExactlyWhatWasMeasured() {
        let ids = Set(ProprietarySignal.all.filter(\.verified).map(\.id))
        XCTAssertEqual(ids, [0x104E, 0x104B, 0x1073])
    }

    func testUnverifiedSignalsDoNotCollideWithRealIdentifiers() {
        // The car answered pages 01, 02, 10, 11, F1 and FF. Merope's own ids
        // sit in FE, which it never answered — so a guess can't be mistaken
        // for a measurement.
        for signal in ProprietarySignal.all where !signal.verified && signal.id >= 0xFE00 {
            XCTAssertEqual(signal.id >> 8, 0xFE, "\(signal.name) strayed out of Merope's range")
        }
    }

    func testGateAndPassengerDoorAreDistinctSignals() {
        XCTAssertNotEqual(ProprietarySignal.gate.id, ProprietarySignal.doorFrontRight.id)
        XCTAssertNotEqual(ProprietarySignal.gate.id, ProprietarySignal.anyOpening.id)
    }
}

final class DIDSessionTests: XCTestCase {
    func testScanDIDAsksForTheRightIdentifier() async throws {
        let adapter = MockAdapter(responses: ["220142": "7E8056201421234\r\r"])
        let session = ELM327Session(transport: adapter)
        let replies = try await session.scanDID(0x0142)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].data, [0x12, 0x34])
        let log = await adapter.log
        XCTAssertEqual(log, ["220142"])
    }

    func testReadProprietaryPicksItsOwnModuleOutOfACrowd() async throws {
        // Headers on, two modules answering. Only 75A owns the gate; the
        // other reply is a different module's data at the same identifier.
        let adapter = MockAdapter(responses: [
            "22104E": "7E8 04 62 10 4E 00\r75A 04 62 10 4E FF\r\r",
        ])
        let session = ELM327Session(transport: adapter)
        let value = try await session.readProprietary(.gate)
        XCTAssertEqual(value, 1, "took the wrong module's answer")
    }

    func testReadProprietaryStillWorksWithHeadersOff() async throws {
        // What the emulator and Merope's impersonation send: one anonymous
        // reply, single byte wide.
        let adapter = MockAdapter(responses: ["22104E": "62104EFF\r\r"])
        let session = ELM327Session(transport: adapter)
        let value = try await session.readProprietary(.gate)
        XCTAssertEqual(value, 1)
    }

    func testReadProprietaryRejectsAnAnswerToSomethingElse() async {
        let adapter = MockAdapter(responses: ["22104E": "62104BFF\r\r"])
        let session = ELM327Session(transport: adapter)
        do {
            _ = try await session.readProprietary(.gate)
            XCTFail("accepted the passenger door as the gate")
        } catch {}
    }

    func testScanDIDReturnsEveryResponder() async throws {
        let adapter = MockAdapter(responses: [
            "220100": "7E80462010001\r7E90462010002\r71F037F2231\r\r",
        ])
        let session = ELM327Session(transport: adapter)
        let replies = try await session.scanDID(0x0100)
        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(replies.filter(\.isPositive).map(\.module), [0x7E8, 0x7E9])
    }
}
