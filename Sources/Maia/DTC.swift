/// A diagnostic trouble code, convertible both ways between its wire bytes
/// and the familiar "P0420" form.
public struct DTC: Sendable, Hashable, CustomStringConvertible {
    public let code: String
    let a: UInt8
    let b: UInt8

    private static let systems = ["P", "C", "B", "U"]

    public init(bytes a: UInt8, _ b: UInt8) {
        self.a = a
        self.b = b
        self.code = String(
            format: "%@%d%X%X%X",
            Self.systems[Int(a >> 6)],
            (a >> 4) & 0x03,
            a & 0x0F,
            b >> 4,
            b & 0x0F
        )
    }

    /// Parse "P0420"-style text (as typed by a human or a fault injector).
    public init?(_ text: String) {
        let chars = Array(text.uppercased())
        guard chars.count == 5,
              let system = Self.systems.firstIndex(of: String(chars[0])),
              let d1 = chars[1].wholeNumberValue, (0...3).contains(d1),
              let d2 = chars[2].hexDigitValue,
              let d3 = chars[3].hexDigitValue,
              let d4 = chars[4].hexDigitValue
        else { return nil }
        self.init(bytes: UInt8(system << 6 | d1 << 4 | d2), UInt8(d3 << 4 | d4))
    }

    public var bytes: (UInt8, UInt8) { (a, b) }
    public var description: String { code }
}

/// Mode-01 PID 01: check-engine light and stored-code count.
public struct MILStatus: Sendable, Equatable {
    public let milOn: Bool
    public let dtcCount: Int

    public init(milOn: Bool, dtcCount: Int) {
        self.milOn = milOn
        self.dtcCount = dtcCount
    }
}
