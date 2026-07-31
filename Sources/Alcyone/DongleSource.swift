#if canImport(CoreBluetooth)
import Foundation
import Maia

/// The real-car source: BLE dongle behind the same session as everything else.
public final class DongleSource: TelemetrySource, @unchecked Sendable {
    public let transport: BLEELMTransport
    public let session: ELM327Session
    public let label = "OBD dongle · BLE"
    /// ISO 15765-4, CAN, 11-bit ids, 500 kbit/s — verified on the car
    /// 2026-07-30. Pinning it means the first PID answers immediately instead
    /// of after a 5–15 s search the app used to time out on.
    public let pinnedProtocol: Int? = 6

    public init(nameHint: String? = nil) {
        transport = BLEELMTransport(nameHint: nameHint)
        session = ELM327Session(transport: transport)
    }

    public var isReady: Bool {
        transport.state == .ready
    }

    public func connect() {
        transport.connect()
    }

    public func tick(dt: Double) async {
        // A real car advances its own clock.
    }
}
#endif
