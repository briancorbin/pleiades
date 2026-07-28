import Maia

/// Sterope — "lightning." Watches the reading stream and decides when to warn.
/// Pure logic, no UI: Alcyone renders whatever this returns.

public enum Severity: Sendable, Equatable {
    case warning
    case critical
}

public enum Trigger: Sendable, Equatable {
    case above(Double)
    case below(Double)
}

public struct AlertRule: Sendable, Identifiable {
    public let id: String
    public let pid: PID
    public let trigger: Trigger
    /// Hysteresis: once firing, the value must retreat this far past the
    /// limit to clear. Kills flapping on a value hovering at the line.
    public let clearMargin: Double
    public let severity: Severity
    public let message: String

    public init(
        id: String,
        pid: PID,
        trigger: Trigger,
        clearMargin: Double,
        severity: Severity,
        message: String
    ) {
        self.id = id
        self.pid = pid
        self.trigger = trigger
        self.clearMargin = clearMargin
        self.severity = severity
        self.message = message
    }
}

public struct Alert: Sendable, Identifiable, Equatable {
    public let id: String
    public let severity: Severity
    public let message: String
    public let value: Double
    public let unit: String
}

/// Evaluates rules against each poll's readings, tracking which alerts are
/// live so hysteresis works across evaluations.
public struct SteropeEngine: Sendable {
    public let rules: [AlertRule]
    private var active: Set<String> = []

    public init(rules: [AlertRule]) {
        self.rules = rules
    }

    public mutating func evaluate(_ readings: [UInt8: Double]) -> [Alert] {
        var alerts: [Alert] = []
        for rule in rules {
            guard let value = readings[rule.pid.code] else { continue }
            let wasActive = active.contains(rule.id)
            let firing: Bool
            switch rule.trigger {
            case .above(let limit):
                firing = value > (wasActive ? limit - rule.clearMargin : limit)
            case .below(let limit):
                firing = value < (wasActive ? limit + rule.clearMargin : limit)
            }
            if firing {
                active.insert(rule.id)
                alerts.append(Alert(
                    id: rule.id,
                    severity: rule.severity,
                    message: rule.message,
                    value: value,
                    unit: rule.pid.unit
                ))
            } else {
                active.remove(rule.id)
            }
        }
        return alerts
    }
}

public extension Array where Element == AlertRule {
    /// Starting thresholds for the 2022 FB25. Values in the bus's metric
    /// units; tune against real-drive logs in phase 1.
    static let foresterDefaults: [AlertRule] = [
        AlertRule(id: "coolant.hot", pid: .coolantTemp, trigger: .above(108), clearMargin: 4,
                  severity: .warning, message: "Coolant running hot"),
        AlertRule(id: "coolant.overheat", pid: .coolantTemp, trigger: .above(116), clearMargin: 4,
                  severity: .critical, message: "Coolant overheating — pull over"),
        AlertRule(id: "oil.hot", pid: .oilTemp, trigger: .above(125), clearMargin: 5,
                  severity: .warning, message: "Oil temp high"),
        AlertRule(id: "voltage.low", pid: .controlModuleVoltage, trigger: .below(12.0), clearMargin: 0.3,
                  severity: .warning, message: "Charging voltage low"),
        AlertRule(id: "voltage.critical", pid: .controlModuleVoltage, trigger: .below(11.6), clearMargin: 0.3,
                  severity: .critical, message: "Battery not charging"),
        AlertRule(id: "rpm.redline", pid: .rpm, trigger: .above(6100), clearMargin: 300,
                  severity: .warning, message: "Redline"),
        AlertRule(id: "fuel.low", pid: .fuelLevel, trigger: .below(15), clearMargin: 3,
                  severity: .warning, message: "Fuel low"),
        AlertRule(id: "fuel.critical", pid: .fuelLevel, trigger: .below(8), clearMargin: 2,
                  severity: .critical, message: "Fuel critical"),
    ]
}
