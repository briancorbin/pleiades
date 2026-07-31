/// A signal the car knows but no standard OBD request can retrieve — gate
/// latch, seatbelt buckles, per-wheel TPMS. Reached through mode 22
/// (`ReadDataByIdentifier`), the mechanism manufacturers use for private data.
///
/// **The identifiers below marked verified were measured on the car**, by
/// enumerating a module either side of a physical change and diffing. See
/// `docs/design/did-discovery.md` for the method and
/// `Tests/MaiaTests/DIDScanTests.swift` for the captured evidence.
public struct ProprietarySignal: Sendable, Hashable {
    public let id: UInt16
    public let name: String
    public let unit: String
    /// A few of these are really booleans. The car answers them `FF` for true
    /// and `00` for false — not `01`, which is why "non-zero" is the test.
    public let isBoolean: Bool
    /// Which module answers. A functional request draws replies from a dozen
    /// of them, and the header is the only thing that says which is ours.
    /// Nil means we haven't identified the owner yet.
    public let module: UInt32?
    /// Divisor for integer signals. Merope encodes at one decimal place.
    public let scale: Double
    /// True once the identifier has been confirmed against the real car.
    /// False means it's Merope's own number, useful on the bench and not yet
    /// something the Forester would recognise.
    public let verified: Bool

    public init(
        id: UInt16,
        name: String,
        unit: String = "",
        isBoolean: Bool = false,
        module: UInt32? = nil,
        scale: Double = 10,
        verified: Bool = false
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.isBoolean = isBoolean
        self.module = module
        self.scale = scale
        self.verified = verified
    }

    /// The mode-22 request string, e.g. `22104E`.
    public var command: String {
        String(format: "22%04X", id)
    }

    /// Turn the payload that follows the echoed identifier into a number.
    ///
    /// Width varies: the car answers the latch signals with a single byte,
    /// while Merope encodes its own signals as a scaled uint16. Both work.
    public func decode(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        if isBoolean {
            return bytes.contains { $0 != 0 } ? 1 : 0
        }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Double(value) / scale
    }
}

// MARK: - Verified on the car, 2026-07-30

/// Module `0x75A` answers to the name "Integ. Unit" — Subaru's body
/// integrated unit, which owns the door switches, the gate latch, the
/// interior lighting and the chimes this project started over.
public extension ProprietarySignal {
    static let integUnit: UInt32 = 0x75A

    /// **The one this project exists for.** `FF` with the tailgate open,
    /// `00` with it shut, and unmoved when the passenger door opens — which
    /// is what separates it from `anyOpening` below.
    static let gate = ProprietarySignal(
        id: 0x104E, name: "Rear gate", isBoolean: true,
        module: integUnit, verified: true
    )
    /// Front passenger door. Same evidence, opposite state.
    static let doorFrontRight = ProprietarySignal(
        id: 0x104B, name: "Door FR", isBoolean: true,
        module: integUnit, verified: true
    )
    /// Goes `FF` when *anything* is open. Useful, but not the gate — it was
    /// one of three identifiers that moved on the first diff, and the
    /// passenger-door test is what told them apart.
    static let anyOpening = ProprietarySignal(
        id: 0x1073, name: "Any opening", isBoolean: true,
        module: integUnit, verified: true
    )

    /// Page `0x11` mirrors the same states at different identifiers —
    /// `1117` tracked the gate and `1116` the passenger door exactly.
    /// Kept as a cross-check, not polled.
    static let gateMirror = ProprietarySignal(
        id: 0x1117, name: "Rear gate (page 11)", isBoolean: true,
        module: integUnit, verified: true
    )

    // Neighbours of the two confirmed hits, all `00` while only the
    // passenger door was open. Almost certainly the other three doors —
    // but "almost certainly" isn't measured, so they say so.
    static let doorFrontLeft = ProprietarySignal(
        id: 0x104A, name: "Door FL", isBoolean: true, module: integUnit
    )
    static let doorRearLeft = ProprietarySignal(
        id: 0x104C, name: "Door RL", isBoolean: true, module: integUnit
    )
    static let doorRearRight = ProprietarySignal(
        id: 0x104D, name: "Door RR", isBoolean: true, module: integUnit
    )
}

// MARK: - Merope's own identifiers

/// Not the car's numbers. These are Merope's, in a range the Forester was
/// never seen answering (`0xFExx`), so the bench can carry signals we haven't
/// found on the real car yet. Belts most likely live on `0x788` (Airbag
/// System) and TPMS on `0x75B` (Tire pressure monitor) — enumerate those
/// modules and these get replaced by measurements.
public extension ProprietarySignal {
    static let airbagModule: UInt32 = 0x788
    static let tpmsModule: UInt32 = 0x75B

    static let beltDriver = ProprietarySignal(
        id: 0xFE10, name: "Belt driver", isBoolean: true, module: airbagModule
    )
    static let beltPassenger = ProprietarySignal(
        id: 0xFE11, name: "Belt passenger", isBoolean: true, module: airbagModule
    )
    static let gear = ProprietarySignal(id: 0xFE20, name: "Gear")
    static let ignition = ProprietarySignal(id: 0xFE21, name: "Ignition")
    static let tpmsFrontLeft = ProprietarySignal(
        id: 0xFE30, name: "Front left", unit: "kPa", module: tpmsModule
    )
    static let tpmsFrontRight = ProprietarySignal(
        id: 0xFE31, name: "Front right", unit: "kPa", module: tpmsModule
    )
    static let tpmsRearLeft = ProprietarySignal(
        id: 0xFE32, name: "Rear left", unit: "kPa", module: tpmsModule
    )
    static let tpmsRearRight = ProprietarySignal(
        id: 0xFE33, name: "Rear right", unit: "kPa", module: tpmsModule
    )
}

public extension ProprietarySignal {
    static let latches: [ProprietarySignal] = [
        .gate, .doorFrontLeft, .doorFrontRight, .doorRearLeft, .doorRearRight,
    ]
    static let tpms: [ProprietarySignal] = [
        .tpmsFrontLeft, .tpmsFrontRight, .tpmsRearLeft, .tpmsRearRight,
    ]
    static let all: [ProprietarySignal] = latches + [
        .anyOpening, .beltDriver, .beltPassenger, .gear, .ignition,
    ] + tpms

    /// Measured on the car, as opposed to inferred or invented.
    static var confirmed: [ProprietarySignal] { all.filter(\.verified) }
}

/// Pressure is metric on the wire; psi is a display choice.
public extension Double {
    var kPaAsPSI: Double { self * 0.145038 }
}
