import Foundation

/// Mode-22 (`ReadDataByIdentifier`) discovery.
///
/// The 2022 Forester's OBD-II port is a gateway-isolated diagnostic stub: it
/// carries no broadcast vehicle state at all, so nothing useful can be
/// *overheard* there. But the modules answer `22 xxxx` richly — 14+ addresses
/// respond in the `0x01xx` range. This is the machinery for working out which
/// identifier means what, the only way anyone ever does it: scan a range,
/// change one thing about the car, scan again, and look at what moved.
///
/// Everything here is pure. The car is a source of strings; the parsing,
/// reassembly, and diffing are values the tests can hammer without hardware.

// MARK: - Frames

/// One CAN frame the way an ELM327 prints it with `ATH1` (headers on).
///
/// The ISO-TP PCI byte is still in `bytes` — the adapter only strips it when
/// headers are off, which is exactly the information we need here, since a
/// functional request draws answers from many modules at once.
public struct DIDFrame: Sendable, Equatable {
    /// Responding address. 11-bit in protocol 6, but 29-bit parses too.
    public let header: UInt32
    public let bytes: [UInt8]

    public init(header: UInt32, bytes: [UInt8]) {
        self.header = header
        self.bytes = bytes
    }
}

/// One module's reassembled UDS message.
public struct DIDMessage: Sendable, Equatable {
    public let module: UInt32
    public let bytes: [UInt8]

    public init(module: UInt32, bytes: [UInt8]) {
        self.module = module
        self.bytes = bytes
    }
}

// MARK: - Replies

/// What one module said when asked for one identifier.
public struct DIDReply: Sendable, Equatable {
    public let module: UInt32
    public let did: UInt16
    /// Payload after the echoed identifier, or nil when the module refused.
    public let data: [UInt8]?
    /// UDS negative-response code, set when the module refused.
    public let negativeCode: UInt8?
    /// True when repeat passes at the same vehicle state disagreed — a
    /// counter, a voltage, a timer. Noise for a mark/diff hunt.
    public var volatile: Bool

    public init(module: UInt32, did: UInt16, data: [UInt8]?, negativeCode: UInt8? = nil, volatile: Bool = false) {
        self.module = module
        self.did = did
        self.data = data
        self.negativeCode = negativeCode
        self.volatile = volatile
    }

    public var isPositive: Bool { data != nil }

    /// Stable identity across passes and snapshots.
    public var key: String { String(format: "%03X:%04X", module, did) }
}

/// The refusals worth naming. `requestOutOfRange` is the overwhelming majority
/// of a scan — it's a module saying "that identifier isn't mine", which is a
/// perfectly good answer and not an error.
public enum UDSNegativeCode {
    public static func name(_ code: UInt8) -> String {
        switch code {
        case 0x10: "generalReject"
        case 0x11: "serviceNotSupported"
        case 0x12: "subFunctionNotSupported"
        case 0x13: "incorrectMessageLength"
        case 0x22: "conditionsNotCorrect"
        case 0x31: "requestOutOfRange"
        case 0x33: "securityAccessDenied"
        case 0x35: "invalidKey"
        case 0x78: "responsePending"
        case 0x7E: "serviceNotSupportedInActiveSession"
        case 0x7F: "serviceNotSupportedInActiveSession"
        default: String(format: "unknown(0x%02X)", code)
        }
    }
}

// MARK: - Parsing

public enum DIDScan {
    /// Split a headers-on reply into frames.
    ///
    /// Tolerates both `ATS0` (compact) and `ATS1` (spaced) formatting. In the
    /// compact form the header length is unambiguous from parity alone: an
    /// 11-bit header is 3 hex chars followed by whole bytes, so the line is
    /// odd-length; a 29-bit header is 8, so it's even.
    public static func frames(in raw: String) -> [DIDFrame] {
        raw.split(whereSeparator: \.isNewline).compactMap { frame(in: String($0)) }
    }

    static func frame(in line: String) -> DIDFrame? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Spaced: "7E8 03 62 01 00". Only 11-bit — a spaced 29-bit header is
        // indistinguishable from four data bytes, and protocol 6 is 11-bit.
        if tokens.count > 1, tokens[0].count == 3, tokens.dropFirst().allSatisfy({ $0.count == 2 }) {
            guard let header = UInt32(tokens[0], radix: 16) else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(tokens.count - 1)
            for token in tokens.dropFirst() {
                guard let byte = UInt8(token, radix: 16) else { return nil }
                bytes.append(byte)
            }
            return DIDFrame(header: header, bytes: bytes)
        }

        // Compact: "7E80362010035".
        let chars = Array(tokens.joined())
        guard chars.count >= 5, chars.allSatisfy(\.isHexDigit) else { return nil }
        let headerLength = chars.count % 2 == 1 ? 3 : 8
        guard chars.count > headerLength else { return nil }
        guard let header = UInt32(String(chars.prefix(headerLength)), radix: 16) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity((chars.count - headerLength) / 2)
        for index in stride(from: headerLength, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return DIDFrame(header: header, bytes: bytes)
    }

    /// Reassemble ISO-TP frames into one message per module.
    ///
    /// Single frames complete immediately; only first/consecutive sequences
    /// carry state. That distinction matters: a module that answers
    /// `responsePending` and *then* answers for real sends two single frames,
    /// and concatenating them would corrupt both.
    public static func messages(in raw: String) -> [DIDMessage] {
        var completed: [DIDMessage] = []
        var pending: [UInt32: (remaining: Int, bytes: [UInt8])] = [:]

        for frame in frames(in: raw) {
            guard let pci = frame.bytes.first else { continue }
            switch pci >> 4 {
            case 0x0:
                let length = Int(pci & 0x0F)
                let body = Array(frame.bytes.dropFirst().prefix(length))
                guard length > 0, body.count == length else { continue }
                completed.append(DIDMessage(module: frame.header, bytes: body))
            case 0x1:
                guard frame.bytes.count >= 2 else { continue }
                let length = Int(pci & 0x0F) << 8 | Int(frame.bytes[1])
                let body = Array(frame.bytes.dropFirst(2))
                guard length > body.count else {
                    completed.append(DIDMessage(module: frame.header, bytes: Array(body.prefix(length))))
                    continue
                }
                pending[frame.header] = (length - body.count, body)
            case 0x2:
                guard var entry = pending[frame.header] else { continue }
                let body = Array(frame.bytes.dropFirst().prefix(entry.remaining))
                entry.bytes += body
                entry.remaining -= body.count
                if entry.remaining <= 0 {
                    completed.append(DIDMessage(module: frame.header, bytes: entry.bytes))
                    pending[frame.header] = nil
                } else {
                    pending[frame.header] = entry
                }
            default:
                continue // flow control — the adapter sends those itself
            }
        }
        return completed
    }

    /// Interpret a raw reply as answers to `22 <did>`.
    public static func replies(to did: UInt16, in raw: String) -> [DIDReply] {
        var found: [DIDReply] = []
        for message in messages(in: raw) {
            guard let service = message.bytes.first else { continue }
            switch service {
            case 0x62:
                guard message.bytes.count >= 3 else { continue }
                let echoed = UInt16(message.bytes[1]) << 8 | UInt16(message.bytes[2])
                guard echoed == did else { continue }
                found.append(DIDReply(
                    module: message.module,
                    did: did,
                    data: Array(message.bytes.dropFirst(3))
                ))
            case 0x7F:
                guard message.bytes.count >= 3, message.bytes[1] == 0x22 else { continue }
                found.append(DIDReply(
                    module: message.module,
                    did: did,
                    data: nil,
                    negativeCode: message.bytes[2]
                ))
            default:
                continue
            }
        }

        // `responsePending` is a stall, not an answer. Drop it wherever the
        // module went on to say something real.
        let spokeFor = Set(found.filter { $0.negativeCode != 0x78 }.map(\.module))
        return found.filter { $0.negativeCode != 0x78 || !spokeFor.contains($0.module) }
    }
}

// MARK: - Support bitmasks

public extension DIDScan {
    /// Decode a `22 xx00` reply as a support bitmask.
    ///
    /// The car volunteers its own map, in the same shape mode-01 PID `00`
    /// uses: four bytes, one bit per identifier, covering the 32 that follow
    /// the base — and the last bit chains to the next block.
    ///
    /// Verified against the real car: `74A` answered `00 00 E0 50` for base
    /// `0x0100`, which predicts 0111 0112 0113 011A 011C, and those are
    /// exactly the five identifiers it went on to answer. `78F` and `7DD`
    /// were the only modules with the chain bit set at `0x0120` and the only
    /// two that answered `0x0140`.
    ///
    /// This is what makes discovery tractable: 65,536 identifiers, but the
    /// map costs one request per block.
    static func supportedIdentifiers(mask: [UInt8], base: UInt16) -> [UInt16] {
        var supported: [UInt16] = []
        for (byteIndex, byte) in mask.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                supported.append(base &+ UInt16(byteIndex * 8 + bit) &+ 1)
            }
        }
        return supported
    }

    /// Whether this block's reply points at another block 32 identifiers on —
    /// the low bit of the fourth byte, mirroring the PID walk.
    static func chainsToNextBlock(mask: [UInt8]) -> Bool {
        mask.count >= 4 && mask[3] & 0x01 != 0
    }
}

// MARK: - Snapshots

/// One sweep of a DID range, with the vehicle in one state.
public struct DIDSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    /// What the car was doing — "gate closed", "belt buckled". The whole
    /// method depends on this being written down.
    public let tag: String?
    public let firstDID: UInt16
    public let lastDID: UInt16
    public let passes: Int
    public let replies: [DIDReply]

    public init(
        capturedAt: Date,
        tag: String?,
        firstDID: UInt16,
        lastDID: UInt16,
        passes: Int,
        replies: [DIDReply]
    ) {
        self.capturedAt = capturedAt
        self.tag = tag
        self.firstDID = firstDID
        self.lastDID = lastDID
        self.passes = passes
        self.replies = replies
    }

    public var positives: [DIDReply] { replies.filter(\.isPositive) }
    public var modules: [UInt32] { Set(replies.map(\.module)).sorted() }

    /// Fold repeat passes at the same vehicle state into one snapshot,
    /// flagging anything that disagreed between them as volatile.
    ///
    /// This is what makes the diff readable. A raw sweep of a live car turns
    /// up dozens of counters, voltages and timers that move on their own; if
    /// they aren't marked here they drown the one byte that tracks the gate.
    public static func merge(
        passes: [[DIDReply]],
        tag: String?,
        firstDID: UInt16,
        lastDID: UInt16,
        capturedAt: Date
    ) -> DIDSnapshot {
        var order: [String] = []
        var first: [String: DIDReply] = [:]
        var unstable: Set<String> = []

        for pass in passes {
            for reply in pass {
                guard let seen = first[reply.key] else {
                    first[reply.key] = reply
                    order.append(reply.key)
                    continue
                }
                if seen.data != reply.data || seen.negativeCode != reply.negativeCode {
                    unstable.insert(reply.key)
                }
            }
        }

        let merged = order.compactMap { key -> DIDReply? in
            guard var reply = first[key] else { return nil }
            reply.volatile = unstable.contains(key)
            return reply
        }
        .sorted { ($0.did, $0.module) < ($1.did, $1.module) }

        return DIDSnapshot(
            capturedAt: capturedAt,
            tag: tag,
            firstDID: firstDID,
            lastDID: lastDID,
            passes: passes.count,
            replies: merged
        )
    }
}

// MARK: - Diff

/// One identifier that moved between two snapshots.
public struct DIDDelta: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Answered in both, with different bytes. The interesting case.
        case changed
        /// Refused (or absent) before, answers now.
        case appeared
        /// Answered before, refuses (or absent) now.
        case vanished
    }

    public let module: UInt32
    public let did: UInt16
    public let kind: Kind
    public let before: [UInt8]?
    public let after: [UInt8]?
    /// True when either side saw the value move on its own — likely noise.
    public let volatile: Bool

    public init(module: UInt32, did: UInt16, kind: Kind, before: [UInt8]?, after: [UInt8]?, volatile: Bool) {
        self.module = module
        self.did = did
        self.kind = kind
        self.before = before
        self.after = after
        self.volatile = volatile
    }

    /// Byte positions that differ, for caret-marking the way `recon` does.
    /// A length change counts every position past the shorter of the two.
    public var changedByteIndices: [Int] {
        let a = before ?? []
        let b = after ?? []
        return (0..<max(a.count, b.count)).filter { index in
            let left = index < a.count ? a[index] : nil
            let right = index < b.count ? b[index] : nil
            return left != right
        }
    }
}

public extension DIDScan {
    /// What changed between two sweeps. Volatile identifiers are excluded by
    /// default — they moved without anyone touching the car, so they can't be
    /// evidence about what was touched.
    static func diff(
        from before: DIDSnapshot,
        to after: DIDSnapshot,
        includeVolatile: Bool = false
    ) -> [DIDDelta] {
        let old = Dictionary(before.replies.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.replies.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        var deltas: [DIDDelta] = []
        for key in Set(old.keys).union(new.keys) {
            let a = old[key]
            let b = new[key]
            guard a?.data != b?.data else { continue }

            let kind: DIDDelta.Kind
            switch (a?.data, b?.data) {
            case (nil, .some): kind = .appeared
            case (.some, nil): kind = .vanished
            default: kind = .changed
            }

            let isVolatile = (a?.volatile ?? false) || (b?.volatile ?? false)
            guard includeVolatile || !isVolatile else { continue }

            // Either side identifies it; at least one is non-nil here.
            guard let reply = b ?? a else { continue }
            deltas.append(DIDDelta(
                module: reply.module,
                did: reply.did,
                kind: kind,
                before: a?.data,
                after: b?.data,
                volatile: isVolatile
            ))
        }
        return deltas.sorted { ($0.did, $0.module) < ($1.did, $1.module) }
    }
}

// MARK: - Hex

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
