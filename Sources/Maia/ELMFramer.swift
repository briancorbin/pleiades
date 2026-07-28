/// Reassembles an ELM327 byte stream into complete responses. BLE delivers
/// notifications in arbitrary chunk sizes (often 20-byte MTU slices), so the
/// only reliable framing is "accumulate until the `>` prompt" — this is that,
/// as a pure value type the transports share and the tests can hammer.
public struct ELMFramer: Sendable {
    private var buffer = ""

    public init() {}

    /// Feed one incoming chunk; returns any responses completed by it,
    /// exclusive of the `>` prompt. Partial data stays buffered.
    public mutating func consume(_ chunk: String) -> [String] {
        buffer += chunk
        var responses: [String] = []
        while let promptIndex = buffer.firstIndex(of: ">") {
            responses.append(String(buffer[..<promptIndex]))
            buffer = String(buffer[buffer.index(after: promptIndex)...])
        }
        return responses
    }
}
