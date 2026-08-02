import Foundation
import Maia

/// Renders `docs/signal-registry.json` into `docs/SIGNALS.md`.
///
/// The registry is the single place any of this is written down. The markdown
/// is never hand-edited — it's the JSON, rendered — so the sheet cannot drift
/// from the data. A test in `RegistryDriftTests` closes the other half of the
/// loop by asserting the JSON agrees with `ProprietarySignal.swift`, so the
/// data cannot drift from the code either.
///
/// What's *not* known is tracked as carefully as what is. An identifier that
/// answers with no known meaning is a work item, not an absence — 191 answer
/// on the body integrated unit and five have names.
enum Registry {
    static let jsonPath = "docs/signal-registry.json"
    static let markdownPath = "docs/SIGNALS.md"

    static func run(check: Bool) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegistryError.malformed("top level is not an object")
        }
        let rendered = render(root)

        if check {
            let existing = (try? String(contentsOfFile: markdownPath, encoding: .utf8)) ?? ""
            guard existing == rendered else {
                print("✗ \(markdownPath) is stale — run `pleiades registry` to regenerate")
                exit(1)
            }
            print("✓ \(markdownPath) matches \(jsonPath)")
            return
        }

        try rendered.write(toFile: markdownPath, atomically: true, encoding: .utf8)
        print("Wrote \(markdownPath)")
        summarise(root)
    }

    // MARK: - Rendering

    private static func render(_ root: [String: Any]) -> String {
        var out: [String] = []
        let vehicle = root["vehicle"] as? [String: Any] ?? [:]

        out.append("""
        <!-- Generated from docs/signal-registry.json by `pleiades registry`. Do not edit by hand. -->

        # Signal registry

        Everything this car is known to expose, and **how we know it**. Some of
        it comes from public standards, some from other people's reverse
        engineering, and some was measured in a driveway with a tailgate held
        open — those are very different kinds of true, so every row says which.

        **Vehicle:** \(str(vehicle["year"])) \(str(vehicle["model"])) · \(str(vehicle["engine"])) · \(str(vehicle["platform"]))
        **Protocol:** \(str(vehicle["protocol"]))
        """)

        // Legends first — the whole point is that the labels mean something.
        if let provenance = root["provenance"] as? [String: Any] {
            out.append("## Provenance\n")
            out.append("| Label | Meaning |\n|---|---|")
            for key in provenance.keys.sorted() {
                out.append("| `\(key)` | \(str(provenance[key])) |")
            }
        }
        if let confidence = root["confidence"] as? [String: Any] {
            out.append("\n## Confidence\n")
            out.append("| Label | Meaning |\n|---|---|")
            for key in confidence.keys.sorted() {
                out.append("| `\(key)` | \(str(confidence[key])) |")
            }
        }

        out.append(renderModules(root))
        out.append(renderOpenQuestions(root))
        out.append(renderBuses(root))
        out.append(renderBroadcast(root))
        out.append(renderConventions(root))
        out.append(renderSources(root))

        return out.joined(separator: "\n") + "\n"
    }

    private static func renderModules(_ root: [String: Any]) -> String {
        guard let modules = root["modules"] as? [[String: Any]] else { return "" }
        var out = ["\n## Modules\n"]

        let identified = modules.flatMap { ($0["signals"] as? [[String: Any]]) ?? [] }
            .filter { str($0["confidence"]) == "confirmed" }.count
        out.append("\(modules.count) modules answer diagnostics. **\(identified)** identifiers are confirmed.\n")

        out.append("| Address | Name | Role | Pages | Signals |\n|---|---|---|---|---|")
        for module in modules {
            let signals = (module["signals"] as? [[String: Any]]) ?? []
            let confirmed = signals.filter { str($0["confidence"]) == "confirmed" }.count
            let answering = module["identifiersAnswering"] as? Int
            let count = answering.map { confirmed > 0 ? "\(confirmed) named / \($0) answer" : "\($0) answer, none named" }
                ?? (confirmed > 0 ? "\(confirmed) named" : "—")
            let pages = ((module["pages"] as? [String]) ?? []).joined(separator: " ")
            out.append("| `\(str(module["address"]))` | \(str(module["name"])) | \(str(module["role"], "")) | \(pages.isEmpty ? "—" : "`\(pages)`") | \(count) |")
        }

        // Detail only for modules that actually have something to say.
        for module in modules {
            let signals = (module["signals"] as? [[String: Any]]) ?? []
            let todo = str(module["todo"], "")
            guard !signals.isEmpty || !todo.isEmpty else { continue }

            out.append("\n### `\(str(module["address"]))` — \(str(module["name"]))\n")
            if !todo.isEmpty { out.append("> **Not yet explored.** \(todo)\n") }
            guard !signals.isEmpty else { continue }

            out.append("| Identifier | Signal | Confidence | Provenance | How we know |\n|---|---|---|---|---|")
            for signal in signals {
                var evidence = str(signal["method"], "")
                if let file = signal["evidence"] as? String { evidence += " (`\(file)`)" }
                if let note = signal["note"] as? String { evidence += evidence.isEmpty ? note : " \(note)" }
                let name = str(signal["name"])
                let kind = str(signal["kind"], "")
                let value = signal["trueValue"].map { " — true = `\($0)`" } ?? ""
                out.append("| `\(str(signal["did"]))` | \(name)\(kind == "boolean" ? value : "") | `\(str(signal["confidence"]))` | `\(str(signal["provenance"]))` | \(evidence.isEmpty ? "—" : evidence) |")
            }
        }
        return out.joined(separator: "\n")
    }

    /// The most useful section: what to go and find out next.
    private static func renderOpenQuestions(_ root: [String: Any]) -> String {
        guard let questions = root["openQuestions"] as? [[String: Any]] else { return "" }
        var out = ["\n## What we don't know yet\n"]
        out.append("The work queue. Each of these is answerable with the tools already built.\n")
        for question in questions {
            out.append("**\(str(question["question"]))**\n")
            if let why = question["whyItMatters"] as? String { out.append("- *Why it matters:* \(why)") }
            if let how = question["howToAnswer"] as? String { out.append("- *How to answer:* \(how)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func renderBuses(_ root: [String: Any]) -> String {
        guard let buses = root["buses"] as? [[String: Any]] else { return "" }
        var out = ["\n## Buses\n", "| Bus | Access | Carries | Provenance |\n|---|---|---|---|"]
        for bus in buses {
            out.append("| \(str(bus["name"])) | \(str(bus["access"])) | \(str(bus["carries"], "—")) | `\(str(bus["provenance"]))` |")
        }
        for bus in buses where bus["evidence"] != nil || bus["note"] != nil {
            let detail = [bus["evidence"] as? String, bus["note"] as? String].compactMap { $0 }.joined(separator: " ")
            out.append("\n- **\(str(bus["name"]))** — \(detail)")
        }
        return out.joined(separator: "\n")
    }

    private static func renderBroadcast(_ root: [String: Any]) -> String {
        guard let frames = root["broadcastFrames"] as? [[String: Any]] else { return "" }
        var out = ["\n## Broadcast frames (not reachable at the OBD port)\n"]
        out.append("Community-decoded, from opendbc. These need a bus tap — the OBD port carries no broadcast traffic on this car.\n")
        out.append("| CAN ID | Frame | Signals | Provenance |\n|---|---|---|---|")
        for frame in frames {
            let signals = ((frame["signals"] as? [String]) ?? []).joined(separator: ", ")
            out.append("| `\(str(frame["canID"]))` | \(str(frame["name"])) | \(signals) | `\(str(frame["provenance"]))` |")
        }
        for frame in frames {
            if let note = frame["note"] as? String {
                out.append("\n- **\(str(frame["name"]))** — \(note)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func renderConventions(_ root: [String: Any]) -> String {
        guard let conventions = root["conventions"] as? [[String: Any]] else { return "" }
        var out = ["\n## Conventions this car follows\n"]
        out.append("Hard-won rules. Each one cost an evening to find and saves the next one.\n")
        for convention in conventions {
            out.append("**\(str(convention["name"]))** — `\(str(convention["provenance"]))`\(convention["date"].map { ", \($0)" } ?? "")\n")
            if let detail = convention["detail"] as? String { out.append("\(detail)\n") }
            if let consequence = convention["consequence"] as? String { out.append("> \(consequence)\n") }
        }
        return out.joined(separator: "\n")
    }

    private static func renderSources(_ root: [String: Any]) -> String {
        guard let sources = root["sources"] as? [[String: Any]] else { return "" }
        var out = ["\n## Sources\n", "| Source | License | What it gives us |\n|---|---|---|"]
        for source in sources {
            let name = (source["url"] as? String).map { "[\(str(source["name"]))](\($0))" } ?? str(source["name"])
            out.append("| \(name) | \(str(source["license"], "—")) | \(str(source["note"], "")) |")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Summary

    private static func summarise(_ root: [String: Any]) {
        let modules = (root["modules"] as? [[String: Any]]) ?? []
        let signals = modules.flatMap { ($0["signals"] as? [[String: Any]]) ?? [] }
        func count(_ confidence: String) -> Int {
            signals.filter { str($0["confidence"]) == confidence }.count
        }
        let answering = modules.compactMap { $0["identifiersAnswering"] as? Int }.reduce(0, +)
        let questions = (root["openQuestions"] as? [[String: Any]])?.count ?? 0

        print("""

          \(modules.count) modules · \(count("confirmed")) confirmed · \(count("candidate")) candidate \
        · \(count("rejected")) rejected
          \(answering) identifiers answer on mapped modules; \(answering - count("confirmed")) have no known meaning
          \(questions) open questions
        """)
    }

    private static func str(_ value: Any?, _ fallback: String = "?") -> String {
        (value as? String) ?? (value as? Int).map(String.init) ?? fallback
    }
}

enum RegistryError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String {
        switch self {
        case .malformed(let why): "signal-registry.json is malformed: \(why)"
        }
    }
}
