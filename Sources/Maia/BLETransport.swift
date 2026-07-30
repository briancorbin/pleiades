#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// CoreBluetooth transport for BLE ELM327 dongles (Vgate iCar Pro, Veepeak
/// BLE+, most clones): a GATT "serial port" — commands written to one
/// characteristic, responses arriving as notifications on another.
///
/// Works on macOS and iOS. `pleiades ble` is the intended first-contact
/// tool: it narrates every step, which is what you want the first time an
/// unfamiliar dongle is on the other end.
public final class BLEELMTransport: NSObject, OBDTransport, @unchecked Sendable {
    public enum ConnectionState: Sendable, Equatable {
        case idle
        case poweredOff
        case unauthorized
        case scanning
        case connecting(String)
        case discovering
        case ready
        case failed(String)

        public var describedState: String {
            switch self {
            case .idle: return "idle"
            case .poweredOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission denied"
            case .scanning: return "scanning for adapters…"
            case .connecting(let name): return "connecting to \(name)…"
            case .discovering: return "discovering services…"
            case .ready: return "ready"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    /// GATT layouts real dongles use. The scan accepts any of them, and
    /// falls back to shape-matching for anything unlisted.
    struct ServiceLayout {
        let service: CBUUID
        let write: CBUUID
        let notify: CBUUID
    }

    static let layouts: [ServiceLayout] = [
        // Vgate iCar Pro and most FFF0-family clones
        ServiceLayout(service: CBUUID(string: "FFF0"), write: CBUUID(string: "FFF2"), notify: CBUUID(string: "FFF1")),
        // Veepeak / LELink and other 18F0-family adapters
        ServiceLayout(service: CBUUID(string: "18F0"), write: CBUUID(string: "2AF1"), notify: CBUUID(string: "2AF0")),
        // Nordic UART clones
        ServiceLayout(
            service: CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
            write: CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
            notify: CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        ),
    ]

    public private(set) var state: ConnectionState = .idle
    /// Fires on every state change — the CLI prints these, the app renders them.
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?
    /// Every adapter seen while scanning: (name, RSSI). Useful when the
    /// dongle isn't the only BLE thing in range.
    public var onDiscover: (@Sendable (String, Int) -> Void)?

    private let queue = DispatchQueue(label: "maia.ble.elm")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var framer = ELMFramer()
    private var pendingSend: CheckedContinuation<String, Error>?
    private var sendToken = 0
    private let nameHint: String?
    private let commandTimeout: TimeInterval

    /// `nameHint` filters discovered adapters by name substring, for when
    /// several BLE devices are advertising nearby.
    public init(nameHint: String? = nil, commandTimeout: TimeInterval = 5) {
        self.nameHint = nameHint
        self.commandTimeout = commandTimeout
    }

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

    /// Suspends until the adapter can take commands, or throws with why not.
    public func waitUntilReady(timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready:
                return
            case .failed(let why):
                throw OBDError.busError(why)
            case .poweredOff:
                throw OBDError.busError("Bluetooth is off")
            case .unauthorized:
                throw OBDError.busError("Bluetooth permission denied")
            default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw OBDError.busError("timed out waiting for the adapter (state: \(state.describedState))")
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

                self.queue.asyncAfter(deadline: .now() + self.commandTimeout) { [weak self] in
                    guard let self, self.sendToken == token, self.pendingSend != nil else { return }
                    self.failPending(OBDError.busError("no reply to \(command) within \(Int(self.commandTimeout))s"))
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
            // Unfiltered: plenty of dongles omit their service UUID from the
            // advertisement packet, so filtering by service misses them.
            central.scanForPeripherals(withServices: nil)
        case .poweredOff:
            setState(.poweredOff)
        case .unauthorized:
            setState(.unauthorized)
        case .unsupported:
            setState(.failed("no Bluetooth LE on this machine"))
        case .resetting:
            setState(.failed("Bluetooth is resetting"))
        case .unknown:
            break  // transient; a real state follows
        @unknown default:
            setState(.failed("unexpected Bluetooth state \(central.state.rawValue)"))
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "(unnamed)"
        onDiscover?(name, RSSI.intValue)

        let advertisesOBD = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains { uuid in Self.layouts.contains { $0.service == uuid } } ?? false
        let matchesHint = nameHint.map { name.localizedCaseInsensitiveContains($0) } ?? false
        let looksLikeOBD = ["obd", "vgate", "icar", "veepeak", "elm", "viecar", "konnwei"]
            .contains { name.lowercased().contains($0) }

        guard advertisesOBD || matchesHint || (nameHint == nil && looksLikeOBD) else { return }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        setState(.connecting(name))
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setState(.discovering)
        peripheral.discoverServices(nil)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        setState(.failed(error?.localizedDescription ?? "connection failed"))
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
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let characteristics = service.characteristics ?? []

        // Prefer a known layout; otherwise match by shape — any notifying
        // characteristic plus any writable one in the same service is a
        // serial port, whatever the vendor decided to call it.
        if let layout = Self.layouts.first(where: { $0.service == service.uuid }) {
            writeCharacteristic = characteristics.first { $0.uuid == layout.write } ?? writeCharacteristic
            notifyCharacteristic = characteristics.first { $0.uuid == layout.notify } ?? notifyCharacteristic
        } else if writeCharacteristic == nil, notifyCharacteristic == nil {
            let notifier = characteristics.first { $0.properties.contains(.notify) }
            let writer = characteristics.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            if notifier != nil, writer != nil {
                notifyCharacteristic = notifier
                writeCharacteristic = writer
            }
        }

        if let notifyCharacteristic, !notifyCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        }
        if writeCharacteristic != nil, notifyCharacteristic != nil, state != .ready {
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

/// Describes what a BLE dongle exposes — used by `pleiades ble --inspect`
/// so an unfamiliar adapter can be mapped without guessing.
public struct BLEServiceReport: Sendable {
    public let serviceUUID: String
    public let characteristics: [(uuid: String, properties: [String])]
}
#endif
