/// Anything that can carry ELM327-style commands to an OBD adapter and return
/// its reply: a WiFi TCP socket, a BLE characteristic pair, or Electra's
/// emulator on the bench.
public protocol OBDTransport: Sendable {
    /// Send one command (no trailing carriage return) and return the raw
    /// response text, exclusive of the terminating `>` prompt.
    func send(_ command: String) async throws -> String
}
