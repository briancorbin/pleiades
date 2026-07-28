import XCTest
@testable import Electra
import Maia

/// The point of Electra: Maia's real session, unmodified, against the fake car.
final class PipelineTests: XCTestCase {
    func testSessionInitializesAgainstEmulator() async throws {
        let session = ELM327Session(transport: ELM327Emulator(car: ElectraCar()))
        try await session.initialize()
    }

    func testSupportedPIDsRoundTripsThroughBitmaskPages() async throws {
        let session = ELM327Session(transport: ELM327Emulator(car: ElectraCar()))
        let supported = try await session.supportedPIDs()
        let catalog = Set(PID.all.map(\.code))
        XCTAssertTrue(supported.isSuperset(of: catalog))
        // Catalog plus the two next-page markers (20, 40).
        XCTAssertEqual(supported.count, catalog.count + 2)
    }

    func testIdleRPMReadsThroughSession() async throws {
        let car = ElectraCar()
        await car.startEngine()
        await car.advance(by: 2)
        let session = ELM327Session(transport: ELM327Emulator(car: car))
        let rpm = try await session.read(.rpm)
        XCTAssertEqual(rpm.value, 650, accuracy: 5)
    }

    func testUnsupportedPIDAnswersNoData() async throws {
        let emulator = ELM327Emulator(car: ElectraCar(), supported: [0x0C])
        let session = ELM327Session(transport: emulator)
        do {
            _ = try await session.read(.coolantTemp)
            XCTFail("expected noData")
        } catch let error as OBDError {
            XCTAssertEqual(error, .noData)
        }
    }
}

final class CarModelTests: XCTestCase {
    func testColdStartWarmsTowardOperatingTemp() async {
        let car = ElectraCar()
        await car.startEngine()
        for _ in 0..<60 {
            await car.advance(by: 10)
        }
        let snapshot = await car.snapshot()
        XCTAssertGreaterThan(snapshot.coolantC, 85)
        XCTAssertLessThanOrEqual(snapshot.coolantC, 90.5)
    }

    func testThrottleDrivesRPMAndSpeed() async {
        let car = ElectraCar()
        await car.startEngine()
        await car.setThrottle(50)
        await car.advance(by: 1)
        let snapshot = await car.snapshot()
        XCTAssertGreaterThan(snapshot.rpm, 2000)
        XCTAssertGreaterThan(snapshot.speedKmh, 0)
    }

    func testEngineOffReadsLikeParkedCar() async {
        let car = ElectraCar()
        let snapshot = await car.snapshot()
        XCTAssertEqual(snapshot.rpm, 0)
        XCTAssertEqual(snapshot.voltage, 12.4)
        XCTAssertEqual(snapshot.mapKPa, 101)  // no vacuum, engine off
    }

    func testVoltageTracksEngineState() async {
        let car = ElectraCar()
        await car.startEngine()
        var snapshot = await car.snapshot()
        XCTAssertEqual(snapshot.voltage, 13.9)
        await car.stopEngine()
        snapshot = await car.snapshot()
        XCTAssertEqual(snapshot.voltage, 12.4)
    }
}
