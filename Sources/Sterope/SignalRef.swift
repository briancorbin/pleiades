import Maia

/// What a rule watches. Standard PIDs and proprietary CAN signals share one
/// numeric namespace — PID codes occupy 0x00–0xFF, proprietary signals live
/// above — so a rule doesn't care which kind it's pointed at.
public enum SignalRef: Sendable, Hashable {
    case pid(PID)
    case proprietary(ProprietarySignal)

    public var id: UInt16 {
        switch self {
        case .pid(let pid): return UInt16(pid.code)
        case .proprietary(let signal): return signal.id
        }
    }

    public var name: String {
        switch self {
        case .pid(let pid): return pid.name
        case .proprietary(let signal): return signal.name
        }
    }

    public var unit: String {
        switch self {
        case .pid(let pid): return pid.unit
        case .proprietary(let signal): return signal.unit
        }
    }

    /// Booleans render as on/off rather than a number with a threshold.
    public var isBoolean: Bool {
        switch self {
        case .pid: return false
        case .proprietary(let signal): return signal.isBoolean
        }
    }

    /// Resolve an id back to a signal — PID codes first, then proprietary.
    public static func resolve(_ id: UInt16) -> SignalRef? {
        if id <= 0xFF, let pid = PID.all.first(where: { $0.code == UInt8(id) }) {
            return .pid(pid)
        }
        if let signal = ProprietarySignal.all.first(where: { $0.id == id }) {
            return .proprietary(signal)
        }
        return nil
    }

    /// Everything a rule can be pointed at, PIDs first.
    public static var all: [SignalRef] {
        PID.all.map { .pid($0) } + ProprietarySignal.all.map { .proprietary($0) }
    }
}
