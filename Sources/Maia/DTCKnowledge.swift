import Foundation

/// Human-readable interpretation of a trouble code. Specific entries for
/// codes worth knowing cold (with Subaru-flavored causes); then the bundled
/// 9,400-code dataset; everything else falls back to the SAE code structure,
/// which always decodes to *something*.
public struct DTCInfo: Sendable, Equatable {
    public let title: String
    public let likelyCauses: [String]
    /// True when this came from the structural fallback, not a specific entry.
    public let isGeneric: Bool
}

public extension DTC {
    var info: DTCInfo { DTCKnowledge.lookup(code) }
    /// "Powertrain", "Chassis", "Body", or "Network".
    var system: String { DTCKnowledge.system(of: code) }
}

enum DTCKnowledge {
    /// Resolution order: curated entry (has causes) → Subaru-specific dataset
    /// → generic SAE dataset → structural fallback from the code digits.
    static func lookup(_ code: String) -> DTCInfo {
        if let known = known[code] {
            return known
        }
        if let subaru = dataset.subaru[code] {
            return DTCInfo(title: "\(subaru) (Subaru)", likelyCauses: [], isGeneric: false)
        }
        if let generic = dataset.generic[code] {
            return DTCInfo(title: generic, likelyCauses: [], isGeneric: false)
        }
        return DTCInfo(title: fallbackTitle(for: code), likelyCauses: [], isGeneric: true)
    }

    /// Bundled descriptions vendored from Wal33D/dtc-database (MIT) — see
    /// Resources/ATTRIBUTION.md.
    private struct Dataset: Decodable {
        let generic: [String: String]
        let subaru: [String: String]
    }

    private static let dataset: Dataset = {
        guard let url = Bundle.module.url(forResource: "dtc-codes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let db = try? JSONDecoder().decode(Dataset.self, from: data)
        else { return Dataset(generic: [:], subaru: [:]) }
        return db
    }()

    static func system(of code: String) -> String {
        switch code.first {
        case "P": return "Powertrain"
        case "C": return "Chassis"
        case "B": return "Body"
        case "U": return "Network"
        default: return "Unknown"
        }
    }

    private static func fallbackTitle(for code: String) -> String {
        let chars = Array(code)
        guard chars.count == 5 else { return "Unrecognized code" }
        if chars[1] != "0" {
            return "Manufacturer-specific \(system(of: code).lowercased()) code"
        }
        guard chars[0] == "P" else {
            return "Generic \(system(of: code).lowercased()) code"
        }
        switch chars[2] {
        case "1", "2": return "Fuel and air metering"
        case "3": return "Ignition system or misfire"
        case "4": return "Auxiliary emission controls"
        case "5": return "Vehicle speed and idle control"
        case "6": return "Computer output circuit"
        case "7", "8", "9": return "Transmission"
        default: return "Fuel and air metering"
        }
    }

    private static let known: [String: DTCInfo] = [
        "P0420": DTCInfo(
            title: "Catalyst efficiency below threshold (Bank 1)",
            likelyCauses: ["Aging catalytic converter", "Failing downstream O2 sensor", "Exhaust leak upstream of the sensor"],
            isGeneric: false),
        "P0300": DTCInfo(
            title: "Random/multiple cylinder misfire",
            likelyCauses: ["Worn spark plugs or coils", "Vacuum leak", "Low fuel pressure"],
            isGeneric: false),
        "P0301": DTCInfo(
            title: "Cylinder 1 misfire",
            likelyCauses: ["Spark plug or coil on that cylinder", "Injector", "Compression loss"],
            isGeneric: false),
        "P0302": DTCInfo(
            title: "Cylinder 2 misfire",
            likelyCauses: ["Spark plug or coil on that cylinder", "Injector", "Compression loss"],
            isGeneric: false),
        "P0303": DTCInfo(
            title: "Cylinder 3 misfire",
            likelyCauses: ["Spark plug or coil on that cylinder", "Injector", "Compression loss"],
            isGeneric: false),
        "P0304": DTCInfo(
            title: "Cylinder 4 misfire",
            likelyCauses: ["Spark plug or coil on that cylinder", "Injector", "Compression loss"],
            isGeneric: false),
        "P0128": DTCInfo(
            title: "Coolant temp below thermostat regulating temperature",
            likelyCauses: ["Thermostat stuck open — the classic Subaru cold-thermostat code", "Coolant temp sensor drift"],
            isGeneric: false),
        "P0171": DTCInfo(
            title: "System too lean (Bank 1)",
            likelyCauses: ["Vacuum/intake leak", "Dirty MAF sensor", "Weak fuel pump or clogged filter"],
            isGeneric: false),
        "P0172": DTCInfo(
            title: "System too rich (Bank 1)",
            likelyCauses: ["Leaking injector", "MAF over-reading", "High fuel pressure"],
            isGeneric: false),
        "P0442": DTCInfo(
            title: "EVAP small leak detected",
            likelyCauses: ["Loose or worn gas cap", "Cracked EVAP hose", "Purge/vent valve seal"],
            isGeneric: false),
        "P0455": DTCInfo(
            title: "EVAP large leak detected",
            likelyCauses: ["Gas cap off or badly seated", "Disconnected EVAP hose"],
            isGeneric: false),
        "P0457": DTCInfo(
            title: "EVAP leak — fuel cap loose or off",
            likelyCauses: ["Tighten the cap, drive a warm-up cycle or two"],
            isGeneric: false),
        "P0026": DTCInfo(
            title: "Intake valve control solenoid range (Bank 1) — AVCS",
            likelyCauses: ["Low or dirty oil — check level first", "Oil control valve/solenoid", "Wiring to the solenoid"],
            isGeneric: false),
        "P0028": DTCInfo(
            title: "Intake valve control solenoid range (Bank 2) — AVCS",
            likelyCauses: ["Low or dirty oil — check level first", "Oil control valve/solenoid", "Wiring to the solenoid"],
            isGeneric: false),
        "P0335": DTCInfo(
            title: "Crankshaft position sensor circuit",
            likelyCauses: ["Sensor or its connector", "Reluctor damage", "Wiring chafe"],
            isGeneric: false),
        "P0340": DTCInfo(
            title: "Camshaft position sensor circuit",
            likelyCauses: ["Sensor or its connector", "Timing correlation", "Wiring"],
            isGeneric: false),
        "P0500": DTCInfo(
            title: "Vehicle speed sensor",
            likelyCauses: ["VSS or tone ring", "ABS sensor feed", "Instrument cluster comm"],
            isGeneric: false),
        "P0562": DTCInfo(
            title: "System voltage low",
            likelyCauses: ["Weak battery", "Alternator output", "Corroded ground strap"],
            isGeneric: false),
        "P0700": DTCInfo(
            title: "Transmission control system fault (TCM requested MIL)",
            likelyCauses: ["Read TCM codes for the real story — this one is just the messenger"],
            isGeneric: false),
        "U0100": DTCInfo(
            title: "Lost communication with ECM/PCM",
            likelyCauses: ["CAN bus wiring", "Module power/ground", "A scan tool or tap misbehaving on the bus"],
            isGeneric: false),
        "U0101": DTCInfo(
            title: "Lost communication with TCM",
            likelyCauses: ["CAN bus wiring", "TCM power/ground"],
            isGeneric: false),
    ]
}
