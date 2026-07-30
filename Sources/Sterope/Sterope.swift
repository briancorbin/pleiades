import Maia

/// Sterope — "lightning." Watches the reading stream and decides when to warn.
/// Pure logic, no UI: Alcyone renders whatever this returns.

public enum Severity: String, Sendable, Equatable, Codable {
    case warning
    case critical
}

public enum Trigger: Sendable, Equatable {
    case above(Double)
    case below(Double)
}

public struct AlertRule: Sendable, Identifiable {
    public let id: String
    public let signal: SignalRef
    public let trigger: Trigger
    /// Hysteresis: once firing, the value must retreat this far past the
    /// limit to clear. Kills flapping on a value hovering at the line.
    public let clearMargin: Double
    public let severity: Severity
    public let message: String
    /// Played once when the alert starts firing.
    public let sound: AlertSound
    /// 0…1. Independent of the sound choice, so muting volume and choosing
    /// `.silent` are separate decisions.
    public let volume: Double

    public init(
        id: String,
        signal: SignalRef,
        trigger: Trigger,
        clearMargin: Double,
        severity: Severity,
        message: String,
        sound: AlertSound = .silent,
        volume: Double = 1.0
    ) {
        self.id = id
        self.signal = signal
        self.trigger = trigger
        self.clearMargin = clearMargin
        self.severity = severity
        self.message = message
        self.sound = sound
        self.volume = volume
    }
}

public extension AlertRule {
    /// Convenience for PID-based rules.
    init(
        id: String, pid: PID, trigger: Trigger, clearMargin: Double,
        severity: Severity, message: String,
        sound: AlertSound = .silent, volume: Double = 1.0
    ) {
        self.init(id: id, signal: .pid(pid), trigger: trigger,
                  clearMargin: clearMargin, severity: severity,
                  message: message, sound: sound, volume: volume)
    }
}

public struct Alert: Sendable, Identifiable, Equatable {
    public let id: String
    public let severity: Severity
    public let message: String
    public let value: Double
    public let unit: String
    public let sound: AlertSound
    public let volume: Double

    public init(
        id: String,
        severity: Severity,
        message: String,
        value: Double,
        unit: String,
        sound: AlertSound = .silent,
        volume: Double = 1.0
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.value = value
        self.unit = unit
        self.sound = sound
        self.volume = volume
    }
}

/// Evaluates rules against each poll's readings, tracking which alerts are
/// live so hysteresis works across evaluations.
public struct SteropeEngine: Sendable {
    public let rules: [AlertRule]
    private var active: Set<String> = []

    /// Alerts that started firing on the most recent `evaluate` — the rising
    /// edge, so sound plays once per event instead of once per poll.
    public private(set) var started: [Alert] = []

    public init(rules: [AlertRule]) {
        self.rules = rules
    }

    public mutating func evaluate(_ readings: [UInt16: Double]) -> [Alert] {
        var alerts: [Alert] = []
        var justStarted: [Alert] = []
        for rule in rules {
            guard let value = readings[rule.signal.id] else { continue }
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
                let alert = Alert(
                    id: rule.id,
                    severity: rule.severity,
                    message: rule.message,
                    value: value,
                    unit: rule.signal.unit,
                    sound: rule.sound,
                    volume: rule.volume
                )
                alerts.append(alert)
                if !wasActive {
                    justStarted.append(alert)
                }
            } else {
                active.remove(rule.id)
            }
        }
        started = justStarted
        return alerts
    }
}

public extension Array where Element == AlertRule {
    /// Starting thresholds for the 2022 FB25. Values in the bus's metric
    /// units; tune against real-drive logs in phase 1.
    static let foresterDefaults: [AlertRule] = [
        AlertRule(id: "coolant.hot", pid: .coolantTemp, trigger: .above(108), clearMargin: 4,
                  severity: .warning, message: "Coolant running hot", sound: .builtIn("alert")),
        AlertRule(id: "coolant.overheat", pid: .coolantTemp, trigger: .above(116), clearMargin: 4,
                  severity: .critical, message: "Coolant overheating — pull over", sound: .builtIn("urgent")),
        AlertRule(id: "oil.hot", pid: .oilTemp, trigger: .above(125), clearMargin: 5,
                  severity: .warning, message: "Oil temp high", sound: .builtIn("alert")),
        AlertRule(id: "voltage.low", pid: .controlModuleVoltage, trigger: .below(12.0), clearMargin: 0.3,
                  severity: .warning, message: "Charging voltage low", sound: .builtIn("soft")),
        AlertRule(id: "voltage.critical", pid: .controlModuleVoltage, trigger: .below(11.6), clearMargin: 0.3,
                  severity: .critical, message: "Battery not charging", sound: .builtIn("urgent")),
        AlertRule(id: "rpm.redline", pid: .rpm, trigger: .above(6100), clearMargin: 300,
                  severity: .warning, message: "Redline", sound: .builtIn("chime")),
        AlertRule(id: "fuel.low", pid: .fuelLevel, trigger: .below(15), clearMargin: 3,
                  severity: .warning, message: "Fuel low", sound: .builtIn("soft")),
        AlertRule(id: "fuel.critical", pid: .fuelLevel, trigger: .below(8), clearMargin: 2,
                  severity: .critical, message: "Fuel critical", sound: .builtIn("alert")),

        // Proprietary signals — only fire when a CAN tap is connected, since
        // nothing else can see them. Note what's *not* here: gate ajar and
        // seatbelt. The car already warns about those, so re-raising them as
        // our own alerts would be duplicating a chime rather than doing
        // anything about it. They're chime policies instead (see Chime).
        AlertRule(id: "tpms.fl", signal: .proprietary(.tpmsFrontLeft), trigger: .below(193),
                  clearMargin: 7, severity: .warning, message: "Front left tire low",
                  sound: .builtIn("soft")),
        AlertRule(id: "tpms.fr", signal: .proprietary(.tpmsFrontRight), trigger: .below(193),
                  clearMargin: 7, severity: .warning, message: "Front right tire low",
                  sound: .builtIn("soft")),
        AlertRule(id: "tpms.rl", signal: .proprietary(.tpmsRearLeft), trigger: .below(193),
                  clearMargin: 7, severity: .warning, message: "Rear left tire low",
                  sound: .builtIn("soft")),
        AlertRule(id: "tpms.rr", signal: .proprietary(.tpmsRearRight), trigger: .below(193),
                  clearMargin: 7, severity: .warning, message: "Rear right tire low",
                  sound: .builtIn("soft")),
    ]
}
