/// Speaks the ELM327 AT/PID dialect over any transport: initializes the
/// adapter, requests PIDs, and decodes replies.
public actor ELM327Session {
    private let transport: any OBDTransport

    public init(transport: any OBDTransport) {
        self.transport = transport
    }

    /// Reset the adapter and configure it for clean machine parsing:
    /// no echo, no linefeeds, no spaces, no headers, auto protocol.
    public func initialize() async throws {
        _ = try await transport.send("ATZ")
        for command in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] {
            _ = try await transport.send(command)
        }
    }

    /// Request a single PID and decode it.
    public func read(_ pid: PID) async throws -> OBDReading {
        let raw = try await transport.send(pid.command)
        let payload = try Self.payload(from: raw, mode: pid.mode, code: pid.code)
        guard payload.count >= pid.byteCount else {
            throw OBDError.malformedResponse(raw)
        }
        return OBDReading(pid: pid, value: pid.decode(Array(payload.prefix(pid.byteCount))))
    }

    /// Walk the mode-01 support bitmasks (PIDs 00, 20, 40, …) and return the
    /// set of PID codes this ECU actually answers.
    public func supportedPIDs() async throws -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var page: UInt8 = 0x00
        while true {
            let raw = try await transport.send(String(format: "01%02X", page))
            let payload: [UInt8]
            do {
                payload = try Self.payload(from: raw, mode: 0x01, code: page)
            } catch OBDError.noData {
                break
            }
            guard payload.count >= 4 else { throw OBDError.malformedResponse(raw) }
            for (byteIndex, byte) in payload.prefix(4).enumerated() {
                for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                    supported.insert(page &+ UInt8(byteIndex * 8 + bit) &+ 1)
                }
            }
            let nextPage = page &+ 0x20
            guard nextPage > page, supported.contains(nextPage) else { break }
            page = nextPage
        }
        return supported
    }

    /// Strip ELM chrome from a raw response and return the payload bytes that
    /// follow the `mode|0x40, code` reply header.
    static func payload(from raw: String, mode: UInt8, code: UInt8) throws -> [UInt8] {
        let cleaned = raw
            .replacingOccurrences(of: "SEARCHING...", with: "")
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        if cleaned.contains("NODATA") { throw OBDError.noData }
        if cleaned.contains("UNABLETOCONNECT") { throw OBDError.unableToConnect }
        if cleaned.contains("CANERROR") || cleaned.contains("BUSERROR") || cleaned.contains("STOPPED") {
            throw OBDError.busError(cleaned)
        }

        let chars = Array(cleaned)
        guard !chars.isEmpty, chars.count % 2 == 0 else {
            throw OBDError.malformedResponse(raw)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else {
                throw OBDError.malformedResponse(raw)
            }
            bytes.append(byte)
        }
        guard bytes.count >= 2, bytes[0] == mode | 0x40, bytes[1] == code else {
            throw OBDError.malformedResponse(raw)
        }
        return Array(bytes.dropFirst(2))
    }
}
