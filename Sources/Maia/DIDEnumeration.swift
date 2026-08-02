import Foundation

/// Reading everything a module admits to having, by walking its own support
/// bitmasks rather than sweeping ranges blind.
///
/// This lives in Maia rather than the CLI because the app needs it too. The
/// discovery workflow — capture, change one thing, capture again, look at
/// what moved — is the same whether it's driven from a laptop or from an
/// iPad sitting on the passenger seat, and it shouldn't exist twice.
public extension ELM327Session {
    /// Walk one page: read the block markers, decode what they advertise,
    /// follow the chain, then read only the identifiers that exist.
    ///
    /// A page costs up to eight mask reads plus however many identifiers are
    /// really there, instead of 256 requests that are mostly
    /// `requestOutOfRange`.
    func enumeratePage(_ page: UInt8, onProgress: (@Sendable (UInt8, Int, Int) -> Void)? = nil) async throws -> [DIDReply] {
        var out: [DIDReply] = []
        var advertised: [UInt16] = []
        var base = UInt16(page) << 8

        // Blocks step by 0x20, each mask covering the 32 identifiers after
        // it, the last bit chaining onward — the same shape as the PID walk.
        for _ in 0..<8 {
            guard let mask = (try? await scanDID(base))?.first(where: \.isPositive),
                  let bytes = mask.data
            else { break }
            out.append(mask)
            advertised += DIDScan.supportedIdentifiers(mask: bytes, base: base)
            guard DIDScan.chainsToNextBlock(mask: bytes) else { break }
            let next = base &+ 0x20
            guard next > base else { break }
            base = next
        }

        // The block markers advertise themselves as the chain link; reading
        // them again as data would double-count.
        let targets = advertised.filter { $0 & 0x1F != 0 }
        var answered = 0
        for did in targets {
            guard let replies = try? await scanDID(did) else { continue }
            out += replies
            answered += replies.filter(\.isPositive).count
        }

        onProgress?(page, targets.count, answered)
        return out
    }

    /// Enumerate several pages into one snapshot, repeating to flag values
    /// that move on their own.
    ///
    /// Two passes is the default everywhere for the same reason: a running
    /// car has counters, voltages and timers that drift, and anything that
    /// disagrees between two passes at the same state can't be evidence
    /// about something nobody did.
    func enumerate(
        module: UInt32,
        pages: [UInt8],
        passes: Int = 2,
        tag: String? = nil,
        onProgress: (@Sendable (UInt8, Int, Int) -> Void)? = nil
    ) async throws -> DIDSnapshot {
        // Narrow the receive filter to this module. Fifteen answering the
        // same functional request costs responses.
        _ = try? await send(String(format: "ATCRA%03X", module))
        defer { Task { _ = try? await self.resetReceiveFilter() } }

        var collected: [[DIDReply]] = []
        for _ in 0..<max(1, passes) {
            var replies: [DIDReply] = []
            for page in pages {
                replies += try await enumeratePage(page, onProgress: onProgress)
            }
            collected.append(replies)
        }

        let identifiers = collected.flatMap { $0 }.map(\.did)
        return DIDSnapshot.merge(
            passes: collected,
            tag: tag,
            firstDID: identifiers.min() ?? 0,
            lastDID: identifiers.max() ?? 0,
            capturedAt: Date()
        )
    }
}
