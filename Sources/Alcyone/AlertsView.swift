import Maia
import Sterope
import SwiftUI

/// Sterope's home: the alert rules, editable. Changes persist to the
/// RuleStore and apply to the live engine immediately.
public struct AlertsView: View {
    @ObservedObject var model: TelemetryModel
    let store: RuleStore

    @State private var rules: [StoredRule] = []
    @State private var editingRule: StoredRule?
    @State private var confirmingReset = false

    public init(model: TelemetryModel, store: RuleStore) {
        self.model = model
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                ForEach(rules) { rule in
                    ruleCard(rule)
                }
                actions
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task {
            rules = await store.all()
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule) { saved in
                if let index = rules.firstIndex(where: { $0.id == saved.id }) {
                    rules[index] = saved
                } else {
                    rules.append(saved)
                }
                persist()
            } onDelete: { deleted in
                rules.removeAll { $0.id == deleted.id }
                persist()
            }
        }
        .confirmationDialog("Reset to Forester defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                Task {
                    rules = await store.resetToDefaults()
                    model.setRules(rules.alertRules())
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces all custom rules with the built-in starting set.")
        }
    }

    private func persist() {
        let snapshot = rules
        Task {
            await store.save(snapshot)
            model.setRules(snapshot.alertRules())
        }
    }

    private var header: some View {
        HStack {
            Text("ALERT RULES")
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.text)
            Text("⚡ Sterope")
                .font(.system(size: 11))
                .foregroundStyle(Theme.copper)
            Spacer()
            Text("\(rules.filter(\.enabled).count) active")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
        }
    }

    private func ruleCard(_ rule: StoredRule) -> some View {
        let isCritical = rule.severity == .critical
        let color: Color = isCritical ? Theme.redline : Theme.copper
        return HStack(spacing: 12) {
            Image(systemName: isCritical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(rule.enabled ? color : Theme.textDim)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(rule.enabled ? Theme.text : Theme.textDim)
                Text(conditionText(rule))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Toggle("", isOn: enabledBinding(rule))
                .labelsHidden()
                .tint(Theme.copper)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            editingRule = rule
        }
    }

    private func conditionText(_ rule: StoredRule) -> String {
        let name = rule.pid?.name ?? String(format: "PID %02X", rule.pidCode)
        let unit = rule.pid?.unit ?? ""
        let comparator = rule.kind == .above ? ">" : "<"
        return "\(name) \(comparator) \(rule.limit.formatted()) \(unit)  ·  clears at ±\(rule.clearMargin.formatted())"
    }

    private func enabledBinding(_ rule: StoredRule) -> Binding<Bool> {
        Binding(
            get: { rules.first { $0.id == rule.id }?.enabled ?? false },
            set: { newValue in
                if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[index].enabled = newValue
                    persist()
                }
            }
        )
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                editingRule = StoredRule(
                    pidCode: PID.coolantTemp.code, kind: .above, limit: 100,
                    clearMargin: 4, severity: .warning, message: "New alert"
                )
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.copper)

            Button("Reset to defaults") {
                confirmingReset = true
            }
            .buttonStyle(.bordered)
            .tint(Theme.textDim)
            Spacer()
        }
    }
}

/// Edit sheet for a single rule.
struct RuleEditorView: View {
    @State var rule: StoredRule
    let onSave: (StoredRule) -> Void
    let onDelete: (StoredRule) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EDIT RULE")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textDim)

            labeledRow("Message") {
                TextField("", text: $rule.message, prompt: Text("What the banner says"))
                    .textFieldStyle(.roundedBorder)
            }
            labeledRow("Signal") {
                Picker("", selection: $rule.pidCode) {
                    ForEach(PID.all, id: \.code) { pid in
                        Text("\(pid.name) (\(pid.unit))").tag(pid.code)
                    }
                }
                .labelsHidden()
            }
            labeledRow("Trigger") {
                Picker("", selection: $rule.kind) {
                    Text("Above").tag(StoredRule.Kind.above)
                    Text("Below").tag(StoredRule.Kind.below)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 16) {
                labeledRow("Limit") {
                    TextField("", value: $rule.limit, format: .number, prompt: Text("0"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                labeledRow("Clear margin") {
                    TextField("", value: $rule.clearMargin, format: .number, prompt: Text("0"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            labeledRow("Severity") {
                Picker("", selection: $rule.severity) {
                    Text("Warning").tag(Severity.warning)
                    Text("Critical").tag(Severity.critical)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer()

            HStack {
                Button("Delete", role: .destructive) {
                    onDelete(rule)
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Save") {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.copper)
                .disabled(rule.message.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 380)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func labeledRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textDim)
            content()
        }
    }
}
