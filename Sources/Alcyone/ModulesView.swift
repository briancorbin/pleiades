import Maia
import Sterope
import SwiftUI

/// Everything the car is known to expose, browsable.
///
/// The other tabs show what the car is *doing*. This one shows what it *is* —
/// fifteen modules, their identifiers, and for each one how much we actually
/// know about it. Deliberately including the parts we don't: 242 identifiers
/// answer across these modules and about a dozen have meanings, so the honest
/// view is mostly unknowns, presented as a work queue rather than hidden.
///
/// Reads `VehicleRegistry`, which is the same JSON that renders
/// `docs/SIGNALS.md` and is drift-tested against `ProprietarySignal`. There's
/// no second copy of this data to go stale.
public struct ModulesView: View {
    @ObservedObject var model: TelemetryModel
    let ruleStore: RuleStore?
    private let registry = VehicleRegistry.shared

    public init(model: TelemetryModel, ruleStore: RuleStore? = nil) {
        self.model = model
        self.ruleStore = ruleStore
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let registry {
                    list(registry)
                } else {
                    // Plain views rather than ContentUnavailableView, which
                    // needs macOS 14 and the package targets 13.
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.textDim)
                        Text("No registry bundled")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("signal-registry.json is missing from the app bundle.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle("Modules")
        }
        .preferredColorScheme(.dark)
    }

    private func list(_ registry: VehicleRegistry) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                summary(registry)
                ForEach(registry.modules) { module in
                    NavigationLink {
                        ModuleDetailView(module: module, model: model, ruleStore: ruleStore)
                    } label: {
                        moduleRow(module)
                    }
                    .buttonStyle(.plain)
                }
                if !registry.openQuestions.isEmpty {
                    openQuestions(registry)
                }
            }
            .padding(18)
        }
    }

    private func summary(_ registry: VehicleRegistry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(registry.vehicle.year) \(registry.vehicle.model)".uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.copper)
            Text("\(registry.modules.count) modules · \(registry.count(.confirmed)) identifiers confirmed · \(registry.unknownCount) still unknown")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Text(registry.vehicle.obdProtocol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func moduleRow(_ module: VehicleRegistry.Module) -> some View {
        HStack(spacing: 12) {
            Text(module.label)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.copper)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(module.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let role = module.role {
                    Text(role)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    if module.count(.confirmed) > 0 {
                        badge("\(module.count(.confirmed)) confirmed", Theme.copper)
                    }
                    if module.count(.candidate) > 0 {
                        badge("\(module.count(.candidate)) candidate", Theme.textDim)
                    }
                    if module.unknownCount > 0 {
                        badge("\(module.unknownCount) unknown", Theme.textDim.opacity(0.6))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textDim.opacity(0.5))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func openQuestions(_ registry: VehicleRegistry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT WE DON'T KNOW YET")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.textDim)
            ForEach(registry.openQuestions) { question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let how = question.howToAnswer {
                        Text(how)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Detail

struct ModuleDetailView: View {
    let module: VehicleRegistry.Module
    @ObservedObject var model: TelemetryModel
    let ruleStore: RuleStore?
    @State private var watching: Set<UInt16> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let todo = module.todo {
                    note("NOT YET EXPLORED", todo)
                }
                ForEach(VehicleRegistry.Confidence.allCases, id: \.self) { confidence in
                    let signals = module.signals.filter { $0.confidence == confidence }
                    if !signals.isEmpty {
                        section(confidence, signals)
                    }
                }
                if module.unknownCount > 0 {
                    note(
                        "\(module.unknownCount) MORE ANSWER",
                        "This module answers \(module.identifiersAnswering) identifiers in total. "
                        + "The rest have no known meaning yet — an enumeration either side of a "
                        + "physical change is what names them."
                    )
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .navigationTitle(module.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(module.label)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.copper)
            if let role = module.role {
                Text(role).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            if !module.pages.isEmpty {
                Text("Pages: \(module.pages.joined(separator: " "))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func section(
        _ confidence: VehicleRegistry.Confidence,
        _ signals: [VehicleRegistry.Signal]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confidence.label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(confidence == .confirmed ? Theme.copper : Theme.textDim)
            Text(confidence.detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim.opacity(0.8))
            ForEach(signals) { signal in
                signalRow(signal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func signalRow(_ signal: VehicleRegistry.Signal) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(signal.command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(signal.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                liveValue(signal)
            }
            if let method = signal.method {
                Text(method)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(signal.provenance.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textDim.opacity(0.7))
                if let date = signal.date {
                    Text(date).font(.system(size: 9)).foregroundStyle(Theme.textDim.opacity(0.5))
                }
                Spacer()
                if signal.isPollable, ruleStore != nil {
                    watchButton(signal)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Live only for identifiers Maia knows how to read. The rest are
    /// reference material — showing them a value would be inventing one.
    @ViewBuilder
    private func liveValue(_ signal: VehicleRegistry.Signal) -> some View {
        if let known = ProprietarySignal.all.first(where: { $0.id == signal.did }),
           let value = model.proprietaryValue(known) {
            let on = value > 0.5
            Text(known.isBoolean ? (on ? "TRUE" : "false") : String(format: "%.1f", value))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(on && known.isBoolean ? Theme.redline : Theme.textDim)
        } else if signal.isPollable {
            Text("—").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.4))
        }
    }

    private func watchButton(_ signal: VehicleRegistry.Signal) -> some View {
        Button {
            Task { await addRule(for: signal) }
        } label: {
            Label(
                watching.contains(signal.did) ? "Watching" : "Watch this",
                systemImage: watching.contains(signal.did) ? "checkmark.circle.fill" : "bell.badge"
            )
            .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(watching.contains(signal.did) ? Theme.copper : Theme.textDim)
        .disabled(watching.contains(signal.did))
    }

    /// Turn a signal into an alert rule.
    ///
    /// Booleans get "above 0.5", which is the only threshold that means
    /// anything for a yes/no. Quantities get a rule seeded from the current
    /// reading so it starts somewhere sensible, and the Alerts tab is where
    /// it gets tuned.
    private func addRule(for signal: VehicleRegistry.Signal) async {
        guard let store = ruleStore,
              let known = ProprietarySignal.all.first(where: { $0.id == signal.did })
        else { return }

        let limit = known.isBoolean ? 0.5 : (model.proprietaryValue(known) ?? 0)
        let rule = StoredRule(
            id: "module.\(module.label).\(String(format: "%04X", signal.did))",
            signalID: signal.did,
            kind: .above,
            limit: limit,
            clearMargin: known.isBoolean ? 0 : abs(limit) * 0.05,
            severity: .warning,
            message: "\(signal.name) — \(module.name)",
            enabled: true,
            sound: .silent,
            volume: 1.0
        )

        var rules = await store.all()
        guard !rules.contains(where: { $0.id == rule.id }) else {
            watching.insert(signal.did)
            return
        }
        rules.append(rule)
        await store.save(rules)
        model.setRules(rules.alertRules())
        watching.insert(signal.did)
    }

    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textDim)
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}
