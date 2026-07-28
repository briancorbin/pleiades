/// Metric is what the bus speaks; imperial is a display decision.
public enum Units {
    public static func mph(_ kmh: Double) -> Double {
        kmh * 0.621371
    }

    public static func miles(_ km: Double) -> Double {
        km * 0.621371
    }

    public static func fahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }
}
