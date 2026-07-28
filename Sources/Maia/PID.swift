/// One OBD-II parameter: how to request it and how to turn the raw payload
/// bytes into a number.
public struct PID: Sendable {
    public let mode: UInt8
    public let code: UInt8
    public let name: String
    public let unit: String
    /// Payload bytes the decoder consumes (extra trailing bytes are ignored).
    public let byteCount: Int
    let decode: @Sendable ([UInt8]) -> Double

    public init(
        mode: UInt8 = 0x01,
        code: UInt8,
        name: String,
        unit: String,
        byteCount: Int,
        decode: @escaping @Sendable ([UInt8]) -> Double
    ) {
        self.mode = mode
        self.code = code
        self.name = name
        self.unit = unit
        self.byteCount = byteCount
        self.decode = decode
    }

    /// The request string an ELM327 expects, e.g. `010C` for RPM.
    public var command: String {
        String(format: "%02X%02X", mode, code)
    }
}

extension PID: Hashable {
    public static func == (lhs: PID, rhs: PID) -> Bool {
        lhs.mode == rhs.mode && lhs.code == rhs.code
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mode)
        hasher.combine(code)
    }
}

/// A decoded value fresh off the bus.
public struct OBDReading: Sendable {
    public let pid: PID
    public let value: Double

    public var unit: String { pid.unit }

    public init(pid: PID, value: Double) {
        self.pid = pid
        self.value = value
    }
}

// MARK: - Standard mode-01 catalog

/// The curated polling set from docs/design/architecture.md appendix A.
/// Coverage is a hypothesis until phase 1 validates it against the real
/// FB25D's `supportedPIDs()` walk.
public extension PID {
    static let engineLoad = PID(code: 0x04, name: "Engine load", unit: "%", byteCount: 1) {
        Double($0[0]) / 2.55
    }
    static let coolantTemp = PID(code: 0x05, name: "Coolant temp", unit: "°C", byteCount: 1) {
        Double($0[0]) - 40
    }
    static let shortFuelTrim1 = PID(code: 0x06, name: "Short fuel trim B1", unit: "%", byteCount: 1) {
        Double($0[0]) / 1.28 - 100
    }
    static let longFuelTrim1 = PID(code: 0x07, name: "Long fuel trim B1", unit: "%", byteCount: 1) {
        Double($0[0]) / 1.28 - 100
    }
    static let manifoldPressure = PID(code: 0x0B, name: "Manifold pressure", unit: "kPa", byteCount: 1) {
        Double($0[0])
    }
    static let rpm = PID(code: 0x0C, name: "RPM", unit: "rpm", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) / 4
    }
    static let speed = PID(code: 0x0D, name: "Speed", unit: "km/h", byteCount: 1) {
        Double($0[0])
    }
    static let timingAdvance = PID(code: 0x0E, name: "Timing advance", unit: "°BTDC", byteCount: 1) {
        Double($0[0]) / 2 - 64
    }
    static let intakeAirTemp = PID(code: 0x0F, name: "Intake air temp", unit: "°C", byteCount: 1) {
        Double($0[0]) - 40
    }
    static let maf = PID(code: 0x10, name: "MAF", unit: "g/s", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) / 100
    }
    static let throttle = PID(code: 0x11, name: "Throttle", unit: "%", byteCount: 1) {
        Double($0[0]) / 2.55
    }
    static let fuelLevel = PID(code: 0x2F, name: "Fuel level", unit: "%", byteCount: 1) {
        Double($0[0]) / 2.55
    }
    static let barometricPressure = PID(code: 0x33, name: "Barometric pressure", unit: "kPa", byteCount: 1) {
        Double($0[0])
    }
    static let catalystTempB1S1 = PID(code: 0x3C, name: "Catalyst temp B1S1", unit: "°C", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) / 10 - 40
    }
    static let controlModuleVoltage = PID(code: 0x42, name: "Battery voltage", unit: "V", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) / 1000
    }
    static let ambientAirTemp = PID(code: 0x46, name: "Ambient air temp", unit: "°C", byteCount: 1) {
        Double($0[0]) - 40
    }
    static let runTime = PID(code: 0x1F, name: "Run time", unit: "s", byteCount: 2) {
        Double($0[0]) * 256 + Double($0[1])
    }
    static let distanceWithMIL = PID(code: 0x21, name: "Distance with MIL", unit: "km", byteCount: 2) {
        Double($0[0]) * 256 + Double($0[1])
    }
    static let fuelRailPressure = PID(code: 0x23, name: "Fuel rail pressure", unit: "kPa", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) * 10
    }
    static let distanceSinceCleared = PID(code: 0x31, name: "Distance since codes cleared", unit: "km", byteCount: 2) {
        Double($0[0]) * 256 + Double($0[1])
    }
    static let relativeThrottle = PID(code: 0x45, name: "Relative throttle", unit: "%", byteCount: 1) {
        Double($0[0]) / 2.55
    }
    /// Spotty across model years — gate on `supportedPIDs()`.
    static let oilTemp = PID(code: 0x5C, name: "Oil temp", unit: "°C", byteCount: 1) {
        Double($0[0]) - 40
    }
    /// Spotty across model years — gate on `supportedPIDs()`.
    static let fuelRate = PID(code: 0x5E, name: "Fuel rate", unit: "L/h", byteCount: 2) {
        (Double($0[0]) * 256 + Double($0[1])) / 20
    }

    static let all: [PID] = [
        .engineLoad, .coolantTemp, .shortFuelTrim1, .longFuelTrim1,
        .manifoldPressure, .rpm, .speed, .timingAdvance, .intakeAirTemp,
        .maf, .throttle, .runTime, .distanceWithMIL, .fuelRailPressure,
        .fuelLevel, .distanceSinceCleared, .barometricPressure, .catalystTempB1S1,
        .controlModuleVoltage, .relativeThrottle, .ambientAirTemp, .oilTemp, .fuelRate,
    ]
}
