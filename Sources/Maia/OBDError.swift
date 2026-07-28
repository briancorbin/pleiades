public enum OBDError: Error, Equatable {
    /// The ECU had no answer for this PID (`NO DATA`).
    case noData
    /// The adapter couldn't reach the ECU (`UNABLE TO CONNECT`) — usually
    /// ignition off or wrong protocol.
    case unableToConnect
    /// The adapter reported a bus-level fault (`CAN ERROR`, `BUS ERROR`, …).
    case busError(String)
    /// The response didn't parse as a reply to what we asked.
    case malformedResponse(String)
    /// The transport's underlying connection went away.
    case connectionClosed
}
