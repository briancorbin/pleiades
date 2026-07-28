import Foundation
import Network

/// Transport for WiFi ELM327 adapters, which expose a raw TCP socket
/// (conventionally 192.168.0.10:35000). Also what the CLI bench tool uses.
public actor ELMTCPTransport: OBDTransport {
    private let connection: NWConnection
    private var buffer = ""

    public init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 35000,
            using: .tcp
        )
    }

    public func connect() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { cont.resume() }
                case .failed(let error), .waiting(let error):
                    once.run { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    public func disconnect() {
        connection.cancel()
    }

    public func send(_ command: String) async throws -> String {
        try await write(command + "\r")
        return try await readUntilPrompt()
    }

    private func write(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readUntilPrompt() async throws -> String {
        while true {
            if let promptIndex = buffer.firstIndex(of: ">") {
                let response = String(buffer[..<promptIndex])
                buffer = String(buffer[buffer.index(after: promptIndex)...])
                return response
            }
            buffer += try await receiveChunk()
        }
    }

    private func receiveChunk() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else if isComplete {
                    cont.resume(throwing: OBDError.connectionClosed)
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }
}

/// NWConnection state handlers can fire multiple times; a continuation may
/// resume only once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
