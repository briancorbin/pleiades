/// A signal that exists on the car's own CAN bus but that no OBD request can
/// retrieve — gate latch, seatbelt buckles, per-wheel TPMS. Merope hears
/// these passively and serves them over mode 22 (ReadDataByIdentifier), the
/// same mechanism manufacturers use for proprietary data.
///
/// Identifiers match Merope's signal ids, which live above the 0x00–0xFF
/// range reserved for standard PID codes.
public struct ProprietarySignal: Sendable, Hashable {
    public let id: UInt16
    public let name: String
    public let unit: String
    /// Values arrive as uint16 at one decimal place; a few are really booleans.
    public let isBoolean: Bool

    public init(id: UInt16, name: String, unit: String = "", isBoolean: Bool = false) {
        self.id = id
        self.name = name
        self.unit = unit
        self.isBoolean = isBoolean
    }

    /// The mode-22 request string, e.g. `220100`.
    public var command: String {
        String(format: "22%04X", id)
    }
}

public extension ProprietarySignal {
    static let gate = ProprietarySignal(id: 0x100, name: "Rear gate", isBoolean: true)
    static let doorFrontLeft = ProprietarySignal(id: 0x101, name: "Door FL", isBoolean: true)
    static let doorFrontRight = ProprietarySignal(id: 0x102, name: "Door FR", isBoolean: true)
    static let doorRearLeft = ProprietarySignal(id: 0x103, name: "Door RL", isBoolean: true)
    static let doorRearRight = ProprietarySignal(id: 0x104, name: "Door RR", isBoolean: true)
    static let beltDriver = ProprietarySignal(id: 0x110, name: "Belt driver", isBoolean: true)
    static let beltPassenger = ProprietarySignal(id: 0x111, name: "Belt passenger", isBoolean: true)
    static let gear = ProprietarySignal(id: 0x120, name: "Gear")
    static let ignition = ProprietarySignal(id: 0x121, name: "Ignition")
    static let tpmsFrontLeft = ProprietarySignal(id: 0x130, name: "Front left", unit: "kPa")
    static let tpmsFrontRight = ProprietarySignal(id: 0x131, name: "Front right", unit: "kPa")
    static let tpmsRearLeft = ProprietarySignal(id: 0x132, name: "Rear left", unit: "kPa")
    static let tpmsRearRight = ProprietarySignal(id: 0x133, name: "Rear right", unit: "kPa")

    static let latches: [ProprietarySignal] = [
        .gate, .doorFrontLeft, .doorFrontRight, .doorRearLeft, .doorRearRight,
    ]
    static let tpms: [ProprietarySignal] = [
        .tpmsFrontLeft, .tpmsFrontRight, .tpmsRearLeft, .tpmsRearRight,
    ]
    static let all: [ProprietarySignal] = latches + [
        .beltDriver, .beltPassenger, .gear, .ignition,
    ] + tpms
}

/// Pressure is metric on the wire; psi is a display choice.
public extension Double {
    var kPaAsPSI: Double { self * 0.145038 }
}
