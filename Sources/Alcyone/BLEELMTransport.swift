#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import Maia

/// CoreBluetooth transport for BLE ELM327 dongles (Vgate iCar Pro, Veepeak
/// BLE+, most clones): a GATT "serial port" — commands written to one
/// characteristic, responses arriving as notifications on another.
///
/// Scaffolded against the two documented service layouts (FFF0 and 18F0
/// families). Live validation against the real dongle is SHED-66's
/// driveway session — expect to adjust UUIDs/quirks there, not structure.
public final class BLEELMTransport: NSObject, OBDTransport, @unchecked Sendable {
    public enum ConnectionState: Sendable, Equatable {
        case idle
        case poweredOff
        case scanning
        case connecting
        case discovering
        case ready
        case failed(String)
    }

    private struct ServiceLayout {
        let service: CBUUID
        let write: CBUUID
        let notify: CBUUID
    }

    private static let layouts: [ServiceLayout] = [
        ServiceLayout(service: CBUUID(string: "FFF0"), write: CBUUID(string: "FFF2"), notify: CBUUID(string: "FFF1")),
        ServiceLayout(service: CBUUID(string: "18F0"), write: CBUUID(string: "2AF1"), notify: CBUUID(string: "2AF0")),
    ]

    public private(set) var state: ConnectionState = .idle
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?

    private let queue = DispatchQueue(label: "alcyone.ble.elm")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var framer = ELMFramer()
    private var pendingSend: CheckedContinuation<String, Error>?
    private var sendToken = 0

    public func connect() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    public func disconnect() {
        queue.async {
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.failPending(OBDError.connectionClosed)
            self.setState(.idle)
        }
    }

    public func send(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.state == .ready,
                      let peripheral = self.peripheral,
                      let write = self.writeCharacteristic
                else {
                    continuation.resume(throwing: OBDError.connectionClosed)
                    return
                }
                guard self.pendingSend == nil else {
                    continuation.resume(throwing: OBDError.busError("overlapping send"))
                    return
                }
                self.pendingSend = continuation
                self.sendToken += 1
                let token = self.sendToken

                let type: CBCharacteristicWriteType =
                    write.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(Data((command + "\r").utf8), for: write, type: type)

                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.sendToken == token, self.pendingSend != nil else { return }
                    self.failPending(OBDError.busError("BLE response timeout"))
                }
            }
        }
    }

    // Must be called on `queue`.
    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }

    private func failPending(_ error: Error) {
        pendingSend?.resume(throwing: error)
        pendingSend = nil
    }
}

extension BLEELMTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            setState(.scanning)
            central.scanForPeripherals(withServices: Self.layouts.map(\.service))
        case .poweredOff:
            setState(.poweredOff)
        case .unauthorized:
            setState(.failed("Bluetooth permission denied"))
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        setState(.connecting)
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setState(.discovering)
        peripheral.discoverServices(Self.layouts.map(\.service))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        failPending(OBDError.connectionClosed)
        writeCharacteristic = nil
        notifyCharacteristic = nil
        setState(.failed(error?.localizedDescription ?? "disconnected"))
    }
}

extension BLEELMTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if let layout = Self.layouts.first(where: { $0.service == service.uuid }) {
                peripheral.discoverCharacteristics([layout.write, layout.notify], for: service)
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let layout = Self.layouts.first(where: { $0.service == service.uuid }) else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == layout.write {
                writeCharacteristic = characteristic
            }
            if characteristic.uuid == layout.notify {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if writeCharacteristic != nil, notifyCharacteristic != nil {
            setState(.ready)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == notifyCharacteristic?.uuid, let data = characteristic.value else { return }
        for response in framer.consume(String(decoding: data, as: UTF8.self)) {
            pendingSend?.resume(returning: response)
            pendingSend = nil
        }
    }
}

/// The real-car source: BLE dongle behind the same session as everything else.
public final class DongleSource: TelemetrySource, @unchecked Sendable {
    public let transport: BLEELMTransport
    public let session: ELM327Session
    public let label = "OBD dongle · BLE"

    public init() {
        transport = BLEELMTransport()
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
