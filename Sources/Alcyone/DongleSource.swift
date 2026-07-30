#if canImport(CoreBluetooth)
import Foundation
import Maia

/// The real-car source: BLE dongle behind the same session as everything else.
public final class DongleSource: TelemetrySource, @unchecked Sendable {
    public let transport: BLEELMTransport
    public let session: ELM327Session
    public let label = "OBD dongle · BLE"

    public init(nameHint: String? = nil) {
        transport = BLEELMTransport(nameHint: nameHint)
        session = ELM327Session(transport: transport)
    }

    public func connect() {
        transport.connect()
    }

    public func tick(dt: Double) async {
        // A real car advances its own clock.
    }
}
#endif
