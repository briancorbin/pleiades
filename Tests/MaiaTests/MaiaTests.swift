import XCTest
@testable import Maia

/// Canned-response transport; records every command it's sent.
actor MockAdapter: OBDTransport {
    private var responses: [String: String]
    private(set) var log: [String] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func send(_ command: String) async throws -> String {
        log.append(command)
        return responses[command] ?? "NO DATA\r\r"
    }
}

final class PayloadParsingTests: XCTestCase {
    func testParsesCompactResponse() throws {
        let bytes = try ELM327Session.payload(from: "410C1AF8\r\r", mode: 0x01, code: 0x0C)
        XCTAssertEqual(bytes, [0x1A, 0xF8])
    }

    func testParsesSpacedResponse() throws {
        let bytes = try ELM327Session.payload(from: "41 05 5A \r\r", mode: 0x01, code: 0x05)
        XCTAssertEqual(bytes, [0x5A])
    }

    func testStripsSearchingPreamble() throws {
        let bytes = try ELM327Session.payload(from: "SEARCHING...\r410D42\r\r", mode: 0x01, code: 0x0D)
        XCTAssertEqual(bytes, [0x42])
    }

    func testNoDataThrows() {
        XCTAssertThrowsError(try ELM327Session.payload(from: "NO DATA\r\r", mode: 0x01, code: 0x0C)) {
            XCTAssertEqual($0 as? OBDError, .noData)
        }
    }

    func testUnableToConnectThrows() {
        XCTAssertThrowsError(try ELM327Session.payload(from: "UNABLE TO CONNECT\r\r", mode: 0x01, code: 0x0C)) {
            XCTAssertEqual($0 as? OBDError, .unableToConnect)
        }
    }

    func testWrongEchoedPIDThrows() {
        XCTAssertThrowsError(try ELM327Session.payload(from: "41055A\r\r", mode: 0x01, code: 0x0C))
    }
}

final class DecoderTests: XCTestCase {
    func testRPM() {
        XCTAssertEqual(PID.rpm.decode([0x1A, 0xF8]), 1726.0)
    }

    func testCoolantTemp() {
        XCTAssertEqual(PID.coolantTemp.decode([0x5A]), 50.0)
    }

    func testEngineLoad() {
        XCTAssertEqual(PID.engineLoad.decode([0xFF]), 100.0, accuracy: 0.01)
    }

    func testFuelTrimIsSignedAroundZero() {
        XCTAssertEqual(PID.shortFuelTrim1.decode([0x80]), 0.0)
        XCTAssertEqual(PID.shortFuelTrim1.decode([0x00]), -100.0)
    }

    func testControlModuleVoltage() {
        XCTAssertEqual(PID.controlModuleVoltage.decode([0x33, 0x8F]), 13.199, accuracy: 0.001)
    }

    func testTimingAdvance() {
        XCTAssertEqual(PID.timingAdvance.decode([0x90]), 8.0)
    }
}

final class SessionTests: XCTestCase {
    func testInitializeSendsSetupCommands() async throws {
        let mock = MockAdapter(responses: [
            "ATZ": "ELM327 v1.5\r\r",
            "ATE0": "OK\r\r", "ATL0": "OK\r\r", "ATS0": "OK\r\r",
            "ATH0": "OK\r\r", "ATSP0": "OK\r\r",
        ])
        let session = ELM327Session(transport: mock)
        try await session.initialize()
        let log = await mock.log
        XCTAssertEqual(log, ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"])
    }

    func testInitializeWidensTheFilterForARealAdapter() async throws {
        // Without this the body integrated unit answers 22 104E and the
        // adapter throws the reply away: 0x75A is outside 0x7E8-0x7EF, the
        // only range an ELM327 accepts in protocol 6.
        let mock = MockAdapter(responses: ["ATCF700": "OK\r\r", "ATCM700": "OK\r\r"])
        let session = ELM327Session(transport: mock)
        try await session.initialize(pinnedProtocol: 6, receiveAllModules: true)
        let log = await mock.log
        XCTAssertTrue(log.contains("ATCF700"), "never widened the receive filter")
        XCTAssertTrue(log.contains("ATCM700"))
    }

    func testInitializeLeavesTheFilterAloneByDefault() async throws {
        let mock = MockAdapter(responses: [:])
        let session = ELM327Session(transport: mock)
        try await session.initialize()
        let log = await mock.log
        XCTAssertFalse(log.contains { $0.hasPrefix("ATCF") })
    }

    func testFilterFallsBackToTheWildcardForm() async throws {
        // A clone that doesn't implement CF/CM answers "?".
        let mock = MockAdapter(responses: [
            "ATCF700": "?\r\r", "ATCM700": "?\r\r", "ATCRA7XX": "OK\r\r",
        ])
        let session = ELM327Session(transport: mock)
        let opened = try await session.openReceiveFilter()
        XCTAssertTrue(opened)
        let log = await mock.log
        XCTAssertTrue(log.contains("ATCRA7XX"))
    }

    func testFilterReportsFailureWhenTheAdapterRefusesEverything() async throws {
        let mock = MockAdapter(responses: [
            "ATCF700": "?\r\r", "ATCM700": "?\r\r", "ATCRA7XX": "?\r\r",
        ])
        let session = ELM327Session(transport: mock)
        let opened = try await session.openReceiveFilter()
        XCTAssertFalse(opened, "claimed success on an adapter that said no")
    }

    func testInitializePinsProtocolWhenAsked() async throws {
        // Protocol 6 skips the 5-15s automatic search the app used to time
        // out on against the real car.
        let mock = MockAdapter(responses: [:])
        let session = ELM327Session(transport: mock)
        try await session.initialize(pinnedProtocol: 6)
        let log = await mock.log
        XCTAssertEqual(log.last, "ATSP6")
        XCTAssertFalse(log.contains("ATSP0"))
    }

    func testReadDecodesReading() async throws {
        let mock = MockAdapter(responses: ["010C": "410C1AF8\r\r"])
        let session = ELM327Session(transport: mock)
        let reading = try await session.read(.rpm)
        XCTAssertEqual(reading.value, 1726.0)
        XCTAssertEqual(reading.unit, "rpm")
    }

    func testReadSurfacesNoData() async throws {
        let mock = MockAdapter(responses: [:])
        let session = ELM327Session(transport: mock)
        do {
            _ = try await session.read(.oilTemp)
            XCTFail("expected noData")
        } catch let error as OBDError {
            XCTAssertEqual(error, .noData)
        }
    }

    func testSupportedPIDsWalksBitmaskPages() async throws {
        // 0100 → BE1FA813: 17 PIDs including the page-2 marker (PID 20);
        // 0120 → NO DATA (mock default), so the walk stops after one page.
        let mock = MockAdapter(responses: ["0100": "4100BE1FA813\r\r"])
        let session = ELM327Session(transport: mock)
        let supported = try await session.supportedPIDs()
        XCTAssertTrue(supported.contains(0x0C))  // RPM
        XCTAssertTrue(supported.contains(0x05))  // coolant
        XCTAssertTrue(supported.contains(0x20))  // next-page marker
        XCTAssertFalse(supported.contains(0x02))
        XCTAssertEqual(supported.count, 17)
    }
}

final class DTCTests: XCTestCase {
    func testDecodeFromBytes() {
        XCTAssertEqual(DTC(bytes: 0x04, 0x20).code, "P0420")
        XCTAssertEqual(DTC(bytes: 0x43, 0x21).code, "C0321")
        XCTAssertEqual(DTC(bytes: 0x81, 0x35).code, "B0135")
        XCTAssertEqual(DTC(bytes: 0xC1, 0x00).code, "U0100")
    }

    func testStringRoundTrip() {
        let dtc = DTC("P0420")
        XCTAssertEqual(dtc?.bytes.0, 0x04)
        XCTAssertEqual(dtc?.bytes.1, 0x20)
        XCTAssertNil(DTC("X0420"))
        XCTAssertNil(DTC("P9420"))
    }

    func testReadDTCsParsesCountedReply() async throws {
        let mock = MockAdapter(responses: ["03": "4302042001 28\r\r"])
        let session = ELM327Session(transport: mock)
        let dtcs = try await session.readDTCs()
        XCTAssertEqual(dtcs.map(\.code), ["P0420", "P0128"])
    }

    func testReadDTCsEmptyWhenHealthy() async throws {
        let mock = MockAdapter(responses: ["03": "4300\r\r"])
        let session = ELM327Session(transport: mock)
        let dtcs = try await session.readDTCs()
        XCTAssertEqual(dtcs.count, 0)
    }

    func testMILStatus() async throws {
        let mock = MockAdapter(responses: ["0101": "410182076504\r\r"])
        let session = ELM327Session(transport: mock)
        let status = try await session.milStatus()
        XCTAssertTrue(status.milOn)
        XCTAssertEqual(status.dtcCount, 2)
    }

    func testClearDTCs() async throws {
        let mock = MockAdapter(responses: ["04": "44\r\r"])
        let session = ELM327Session(transport: mock)
        try await session.clearDTCs()
        let log = await mock.log
        XCTAssertEqual(log, ["04"])
    }
}

final class DTCKnowledgeTests: XCTestCase {
    func testKnownCodeHasSpecificEntry() {
        let info = DTC("P0420")!.info
        XCTAssertFalse(info.isGeneric)
        XCTAssertTrue(info.title.contains("Catalyst"))
        XCTAssertFalse(info.likelyCauses.isEmpty)
    }

    func testUnknownGenericCodeFallsBackToSAEFamily() {
        let info = DTC("P0FFF")!.info
        XCTAssertTrue(info.isGeneric)
        XCTAssertEqual(info.title, "Fuel and air metering")
    }

    func testManufacturerSpecificFallback() {
        let info = DTC("P1FFF")!.info
        XCTAssertTrue(info.isGeneric)
        XCTAssertTrue(info.title.contains("Manufacturer-specific"))
    }

    func testSystemNames() {
        XCTAssertEqual(DTC("P0420")!.system, "Powertrain")
        XCTAssertEqual(DTC("C0123")!.system, "Chassis")
        XCTAssertEqual(DTC("B0001")!.system, "Body")
        XCTAssertEqual(DTC("U0100")!.system, "Network")
    }
}

final class FreezeFrameTests: XCTestCase {
    func testReadFreezeFramePID() async throws {
        let mock = MockAdapter(responses: ["020C00": "420C001AF8\r\r"])
        let session = ELM327Session(transport: mock)
        let reading = try await session.readFreezeFrame(.rpm)
        XCTAssertEqual(reading.value, 1726.0)
    }

    func testFreezeFrameDTC() async throws {
        let mock = MockAdapter(responses: ["020200": "4202000420\r\r"])
        let session = ELM327Session(transport: mock)
        let dtc = try await session.freezeFrameDTC()
        XCTAssertEqual(dtc?.code, "P0420")
    }

    func testFreezeFrameDTCNilWhenNoFrame() async throws {
        let mock = MockAdapter(responses: [:])  // NO DATA
        let session = ELM327Session(transport: mock)
        let dtc = try await session.freezeFrameDTC()
        XCTAssertNil(dtc)
    }
}

final class DatasetLookupTests: XCTestCase {
    func testDatasetCoversNonCuratedCode() {
        let info = DTC("P0333")!.info
        XCTAssertFalse(info.isGeneric)
        XCTAssertTrue(info.title.contains("Knock"))
    }

    func testSubaruSpecificWinsOverGeneric() {
        let info = DTC("P1443")!.info
        XCTAssertFalse(info.isGeneric)
        XCTAssertTrue(info.title.contains("(Subaru)"))
        XCTAssertTrue(info.title.contains("EVAP"))
    }

    func testStructuralFallbackForAbsentCode() {
        let info = DTC("P0FFF")!.info
        XCTAssertTrue(info.isGeneric)
    }

    func testCuratedStillWinsOverDataset() {
        let info = DTC("P0420")!.info
        XCTAssertFalse(info.likelyCauses.isEmpty)
    }
}

final class ELMFramerTests: XCTestCase {
    func testSingleCompleteResponse() {
        var framer = ELMFramer()
        XCTAssertEqual(framer.consume("410C1AF8\r\r>"), ["410C1AF8\r\r"])
    }

    func testResponseSplitAcrossChunks() {
        var framer = ELMFramer()
        XCTAssertEqual(framer.consume("410C"), [])
        XCTAssertEqual(framer.consume("1AF8\r"), [])
        XCTAssertEqual(framer.consume("\r>"), ["410C1AF8\r\r"])
    }

    func testMultipleResponsesInOneChunk() {
        var framer = ELMFramer()
        let responses = framer.consume("OK\r>41055A\r>")
        XCTAssertEqual(responses, ["OK\r", "41055A\r"])
    }

    func testTrailingPartialStaysBuffered() {
        var framer = ELMFramer()
        XCTAssertEqual(framer.consume("OK\r>410C"), ["OK\r"])
        XCTAssertEqual(framer.consume("1AF8>"), ["410C1AF8"])
    }
}
