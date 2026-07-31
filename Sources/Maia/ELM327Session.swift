/// Speaks the ELM327 AT/PID dialect over any transport: initializes the
/// adapter, requests PIDs, and decodes replies.
public actor ELM327Session {
    private let transport: any OBDTransport

    public init(transport: any OBDTransport) {
        self.transport = transport
    }

    /// Reset the adapter and configure it for clean machine parsing:
    /// no echo, no linefeeds, no spaces, no headers.
    ///
    /// `pinnedProtocol` skips the adapter's automatic protocol search, which
    /// costs 5–15 s on the first request and can fail outright on a port that
    /// only answers diagnostics. Pass 6 for ISO 15765-4 (CAN, 11-bit, 500
    /// kbit/s) — every Subaru of this era, and most cars since 2008. Nil
    /// leaves the adapter hunting, which is the right default for an unknown
    /// car.
    public func initialize(pinnedProtocol: Int? = nil) async throws {
        _ = try await transport.send("ATZ")
        var setup = ["ATE0", "ATL0", "ATS0", "ATH0"]
        setup.append(pinnedProtocol.map { "ATSP\($0)" } ?? "ATSP0")
        for command in setup {
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

    /// Check-engine light state and stored-code count (mode 01, PID 01).
    public func milStatus() async throws -> MILStatus {
        let raw = try await transport.send("0101")
        let payload = try Self.payload(from: raw, mode: 0x01, code: 0x01)
        guard let a = payload.first else { throw OBDError.malformedResponse(raw) }
        return MILStatus(milOn: a & 0x80 != 0, dtcCount: Int(a & 0x7F))
    }

    /// Stored trouble codes (mode 03). Empty when the car is happy.
    public func readDTCs() async throws -> [DTC] {
        let raw = try await transport.send("03")
        var payload: [UInt8]
        do {
            payload = try Self.payload(from: raw, mode: 0x03, code: nil)
        } catch OBDError.noData {
            return []
        }
        // CAN replies lead with a count byte; K-line style doesn't. Tolerate both.
        if let first = payload.first, Int(first) * 2 == payload.count - 1 {
            payload = Array(payload.dropFirst())
        }
        return stride(from: 0, to: payload.count - 1, by: 2)
            .map { DTC(bytes: payload[$0], payload[$0 + 1]) }
            .filter { $0.bytes != (0, 0) }
    }

    /// Read a proprietary signal via mode 22 (ReadDataByIdentifier). Only a
    /// CAN tap can answer these — a dongle has nothing to ask.
    public func readProprietary(_ signal: ProprietarySignal) async throws -> Double {
        let raw = try await transport.send(signal.command)

        // Headers on: a functional request can draw answers from several
        // modules at once, and only the header says which one is ours. The
        // real car's latch signals come back a single byte wide, so nothing
        // here may assume a fixed width.
        let addressed = DIDScan.replies(to: signal.id, in: raw)
            .filter { signal.module == nil || $0.module == signal.module }
            .first(where: \.isPositive)
        if let data = addressed?.data {
            return signal.decode(data)
        }

        // Headers off: one anonymous reply, which is what the emulator and
        // Merope's impersonation send.
        let payload = try Self.payload(from: raw, mode: 0x22, code: nil)
        guard payload.count >= 3 else { throw OBDError.malformedResponse(raw) }
        let echoed = UInt16(payload[0]) << 8 | UInt16(payload[1])
        guard echoed == signal.id else { throw OBDError.malformedResponse(raw) }
        return signal.decode(Array(payload.dropFirst(2)))
    }

    /// Adapter-level escape hatch for the AT commands the typed API doesn't
    /// cover — `ATH1` before a DID scan, `ATSP6` to pin the protocol.
    public func send(_ command: String) async throws -> String {
        try await transport.send(command)
    }

    /// Ask the whole bus for one identifier (mode 22) and return every answer
    /// separately, refusals included.
    ///
    /// Unlike `readProprietary`, this expects the adapter to have headers on
    /// (`ATH1`): a functional request draws replies from a dozen modules at
    /// once, and without the header they're an anonymous pile. Silence is a
    /// result, not an error — an unanswered identifier returns no replies.
    public func scanDID(_ did: UInt16) async throws -> [DIDReply] {
        let raw = try await transport.send(String(format: "22%04X", did))
        return DIDScan.replies(to: did, in: raw)
    }

    /// Read one PID from a freeze frame (mode 02) — the sensor snapshot the
    /// ECU captured at the instant the code set.
    public func readFreezeFrame(_ pid: PID, frame: UInt8 = 0) async throws -> OBDReading {
        let raw = try await transport.send(String(format: "02%02X%02X", pid.code, frame))
        var payload = try Self.payload(from: raw, mode: 0x02, code: pid.code)
        guard payload.first == frame else { throw OBDError.malformedResponse(raw) }
        payload = Array(payload.dropFirst())
        guard payload.count >= pid.byteCount else { throw OBDError.malformedResponse(raw) }
        return OBDReading(pid: pid, value: pid.decode(Array(payload.prefix(pid.byteCount))))
    }

    /// The code that triggered the freeze frame (mode 02, PID 02), or nil
    /// when no frame is stored.
    public func freezeFrameDTC(frame: UInt8 = 0) async throws -> DTC? {
        let raw = try await transport.send(String(format: "0202%02X", frame))
        var payload: [UInt8]
        do {
            payload = try Self.payload(from: raw, mode: 0x02, code: 0x02)
        } catch OBDError.noData {
            return nil
        }
        guard payload.first == frame else { throw OBDError.malformedResponse(raw) }
        payload = Array(payload.dropFirst())
        guard payload.count >= 2 else { throw OBDError.malformedResponse(raw) }
        if payload[0] == 0, payload[1] == 0 {
            return nil
        }
        return DTC(bytes: payload[0], payload[1])
    }

    /// Clear stored codes and reset the MIL (mode 04). The ECU relearns fuel
    /// trims afterward — deliberate action, never polled.
    public func clearDTCs() async throws {
        let raw = try await transport.send("04")
        _ = try Self.payload(from: raw, mode: 0x04, code: nil)
    }

    /// Strip ELM chrome from a raw response and return the payload bytes that
    /// follow the reply header (`mode|0x40`, plus the echoed PID when `code`
    /// is given — modes 03/04 have no PID byte).
    static func payload(from raw: String, mode: UInt8, code: UInt8?) throws -> [UInt8] {
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
        guard let first = bytes.first, first == mode | 0x40 else {
            throw OBDError.malformedResponse(raw)
        }
        if let code {
            guard bytes.count >= 2, bytes[1] == code else {
                throw OBDError.malformedResponse(raw)
            }
            return Array(bytes.dropFirst(2))
        }
        return Array(bytes.dropFirst(1))
    }
}
