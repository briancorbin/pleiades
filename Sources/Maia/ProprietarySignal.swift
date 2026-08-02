/// A signal the car knows but no standard OBD request can retrieve — gate
/// latch, seatbelt buckles, per-wheel TPMS. Reached through mode 22
/// (`ReadDataByIdentifier`), the mechanism manufacturers use for private data.
///
/// **The identifiers below marked verified were measured on the car**, by
/// enumerating a module either side of a physical change and diffing. See
/// `docs/design/did-discovery.md` for the method and
/// `Tests/MaiaTests/DIDScanTests.swift` for the captured evidence.
/// How a module spells a value.
///
/// **This is not consistent across the car**, which is the kind of thing you
/// only learn by measuring two modules. The body integrated unit answers its
/// latches `00` shut and `FF` open, so "non-zero" is the test. The airbag
/// module answers its buckles `01` unbuckled and `02` buckled — where
/// "non-zero" would report every unfastened seatbelt as fastened.
public enum SignalEncoding: Sendable, Hashable {
    /// True when any byte is non-zero. The `00`/`FF` convention.
    case nonZero
    /// True only for this exact value. The `01`/`02` convention.
    case equals(UInt8)
    /// A big-endian integer divided by this. Merope encodes at one decimal.
    case scaled(Double)
}

public struct ProprietarySignal: Sendable, Hashable {
    public let id: UInt16
    public let name: String
    public let unit: String
    /// How to turn this module's bytes into a number — see `SignalEncoding`.
    public let encoding: SignalEncoding
    /// Whether this reads as a yes/no rather than a quantity.
    public var isBoolean: Bool {
        if case .scaled = encoding { return false }
        return true
    }
    /// Which module answers. A functional request draws replies from a dozen
    /// of them, and the header is the only thing that says which is ours.
    /// Nil means we haven't identified the owner yet.
    public let module: UInt32?
    /// True once the identifier *and* its meaning have been confirmed against
    /// the real car. False covers both Merope's own invented numbers and real
    /// identifiers whose exact meaning is still a hypothesis.
    public let verified: Bool

    public init(
        id: UInt16,
        name: String,
        unit: String = "",
        encoding: SignalEncoding = .scaled(10),
        module: UInt32? = nil,
        verified: Bool = false
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.encoding = encoding
        self.module = module
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
        guard let first = bytes.first else { return 0 }
        switch encoding {
        case .nonZero:
            return bytes.contains { $0 != 0 } ? 1 : 0
        case .equals(let wanted):
            return first == wanted ? 1 : 0
        case .scaled(let divisor):
            let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return Double(value) / divisor
        }
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
        id: 0x104E, name: "Rear gate", encoding: .nonZero,
        module: integUnit, verified: true
    )
    /// Front passenger door. Same evidence, opposite state.
    static let doorFrontRight = ProprietarySignal(
        id: 0x104B, name: "Door FR", encoding: .nonZero,
        module: integUnit, verified: true
    )
    /// Goes `FF` when *anything* is open. Useful, but not the gate — it was
    /// one of three identifiers that moved on the first diff, and the
    /// passenger-door test is what told them apart.
    static let anyOpening = ProprietarySignal(
        id: 0x1073, name: "Any opening", encoding: .nonZero,
        module: integUnit, verified: true
    )

    /// Page `0x11` mirrors the same states at different identifiers —
    /// `1117` tracked the gate and `1116` the passenger door exactly.
    /// Kept as a cross-check, not polled.
    static let gateMirror = ProprietarySignal(
        id: 0x1117, name: "Rear gate (page 11)", encoding: .nonZero,
        module: integUnit, verified: true
    )

    // Neighbours of the two confirmed hits, all `00` while only the
    // passenger door was open. Almost certainly the other three doors —
    // but "almost certainly" isn't measured, so they say so.
    static let doorFrontLeft = ProprietarySignal(
        id: 0x104A, name: "Door FL", encoding: .nonZero, module: integUnit
    )
    static let doorRearLeft = ProprietarySignal(
        id: 0x104C, name: "Door RL", encoding: .nonZero, module: integUnit
    )
    static let doorRearRight = ProprietarySignal(
        id: 0x104D, name: "Door RR", encoding: .nonZero, module: integUnit
    )
}

// MARK: - Merope's own identifiers

/// Module `0x788` — "Airbag System", which owns the buckle switches.
///
/// **It spells booleans differently from the body module:** `01` unbuckled,
/// `02` buckled, where `0x75A` uses `00`/`FF`. Decoding these as "non-zero
/// means true" reports every unfastened belt as fastened, so the encoding is
/// declared per signal rather than assumed per project.
///
/// Not `verified` yet: the four captures were taken buckling belts one after
/// another, and if each stayed fastened as the next went on, `1046` is the
/// driver and `1047` the passenger. If they were done in isolation the
/// reading is different. One capture with *only* the passenger belt fastened
/// settles it.
public extension ProprietarySignal {
    static let airbagModule: UInt32 = 0x788

    static let beltDriver = ProprietarySignal(
        id: 0x1046, name: "Belt driver", encoding: .equals(0x02), module: airbagModule
    )
    static let beltPassenger = ProprietarySignal(
        id: 0x1047, name: "Belt passenger", encoding: .equals(0x02), module: airbagModule
    )
}

// MARK: - Merope's own identifiers

/// Not the car's numbers. These are Merope's, in a range the Forester was
/// never seen answering (`0xFExx`), so the bench can carry signals we haven't
/// found on the real car yet. TPMS most likely lives on `0x75B` (Tire
/// pressure monitor) — enumerate it and these get replaced by measurements.
public extension ProprietarySignal {
    static let tpmsModule: UInt32 = 0x75B

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
