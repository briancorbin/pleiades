import Foundation

/// Snapshots are written to `logs/` and read back by the next scan, but the
/// first reader is usually a person squinting at a diff in the driveway. So
/// they encode as hex strings rather than decimal byte arrays: `"7E8"`,
/// `"0100"`, `"01 04 00 00"` — the same notation as every other tool in this
/// project, greppable and eyeball-comparable.

private enum Hex {
    static func string(_ value: UInt32, width: Int) -> String {
        String(format: "%0\(width)X", value)
    }

    static func bytes(_ text: String) -> [UInt8]? {
        let chars = Array(text.filter { !$0.isWhitespace })
        guard chars.count % 2 == 0, chars.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

extension DIDReply: Codable {
    private enum CodingKeys: String, CodingKey {
        case module, did, data, nrc, volatile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let moduleText = try container.decode(String.self, forKey: .module)
        guard let module = UInt32(moduleText, radix: 16) else {
            throw DecodingError.dataCorruptedError(forKey: .module, in: container, debugDescription: "not hex: \(moduleText)")
        }
        let didText = try container.decode(String.self, forKey: .did)
        guard let did = UInt16(didText, radix: 16) else {
            throw DecodingError.dataCorruptedError(forKey: .did, in: container, debugDescription: "not hex: \(didText)")
        }

        var data: [UInt8]?
        if let text = try container.decodeIfPresent(String.self, forKey: .data) {
            guard let parsed = Hex.bytes(text) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "not hex: \(text)")
            }
            data = parsed
        }

        var negativeCode: UInt8?
        if let text = try container.decodeIfPresent(String.self, forKey: .nrc) {
            guard let parsed = UInt8(text, radix: 16) else {
                throw DecodingError.dataCorruptedError(forKey: .nrc, in: container, debugDescription: "not hex: \(text)")
            }
            negativeCode = parsed
        }

        self.init(
            module: module,
            did: did,
            data: data,
            negativeCode: negativeCode,
            volatile: try container.decodeIfPresent(Bool.self, forKey: .volatile) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Hex.string(module, width: 3), forKey: .module)
        try container.encode(Hex.string(UInt32(did), width: 4), forKey: .did)
        try container.encodeIfPresent(data?.hexString, forKey: .data)
        try container.encodeIfPresent(negativeCode.map { Hex.string(UInt32($0), width: 2) }, forKey: .nrc)
        if volatile {
            try container.encode(true, forKey: .volatile)
        }
    }
}

extension DIDSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case capturedAt, tag, firstDID, lastDID, passes, replies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let stamp = try container.decode(String.self, forKey: .capturedAt)
        guard let capturedAt = ISO8601DateFormatter().date(from: stamp) else {
            throw DecodingError.dataCorruptedError(forKey: .capturedAt, in: container, debugDescription: "not ISO8601: \(stamp)")
        }
        let firstText = try container.decode(String.self, forKey: .firstDID)
        let lastText = try container.decode(String.self, forKey: .lastDID)
        guard let firstDID = UInt16(firstText, radix: 16), let lastDID = UInt16(lastText, radix: 16) else {
            throw DecodingError.dataCorruptedError(forKey: .firstDID, in: container, debugDescription: "not hex: \(firstText)…\(lastText)")
        }

        self.init(
            capturedAt: capturedAt,
            tag: try container.decodeIfPresent(String.self, forKey: .tag),
            firstDID: firstDID,
            lastDID: lastDID,
            passes: try container.decode(Int.self, forKey: .passes),
            replies: try container.decode([DIDReply].self, forKey: .replies)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ISO8601DateFormatter().string(from: capturedAt), forKey: .capturedAt)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encode(Hex.string(UInt32(firstDID), width: 4), forKey: .firstDID)
        try container.encode(Hex.string(UInt32(lastDID), width: 4), forKey: .lastDID)
        try container.encode(passes, forKey: .passes)
        try container.encode(replies, forKey: .replies)
    }
}

public extension DIDSnapshot {
    /// Pretty-printed, key-sorted JSON — snapshots get diffed by eye and by
    /// `git diff` as often as by this tool.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(json: Data) throws {
        self = try JSONDecoder().decode(DIDSnapshot.self, from: json)
    }
}
