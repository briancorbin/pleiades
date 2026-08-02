import Celaeno
import Maia
import SwiftUI

/// Find signals in the car, from the passenger seat.
///
/// The whole method in one screen: capture what a module says, go and change
/// one thing, capture again, and look at what moved. Tap anything that moved
/// and give it a name.
///
/// It's the same procedure the CLI runs, moved to where the car is. Standing
/// at a tailgate reading a terminal on a laptop balanced on the bumper is
/// how the first three findings were made, and it's worse in every way than
/// holding an iPad.
///
/// **Names recorded here don't go straight into the registry.** They land in
/// `FindingStore` and export as a patch to paste back, because the registry's
/// bar is measured-dated-and-evidenced, and clearing that bar is a judgement
/// rather than a file write.
@MainActor
public struct DiscoverView: View {
    @ObservedObject var model: TelemetryModel
    let findingStore: FindingStore?

    @State private var module: UInt32 = ProprietarySignal.integUnit
    @State private var baseline: DIDSnapshot?
    @State private var current: DIDSnapshot?
    @State private var deltas: [DIDDelta] = []
    @State private var phase: Phase = .idle
    @State private var progress = ""
    @State private var baselineTag = ""
    @State private var changedTag = ""
    @State private var naming: DIDDelta?
    @State private var recorded: [String: String] = [:]
    @State private var failure: String?

    enum Phase: Equatable {
        case idle, capturingBaseline, ready, capturingChange, results
    }

    public init(model: TelemetryModel, findingStore: FindingStore? = nil) {
        self.model = model
        self.findingStore = findingStore
    }

    private var registry: VehicleRegistry? { VehicleRegistry.shared }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modulePicker
                    steps
                    if let failure { errorCard(failure) }
                    if phase == .results { results }
                }
                .padding(18)
            }
            .background(Theme.background)
            .navigationTitle("Discover")
        }
        .preferredColorScheme(.dark)
        .sheet(item: $naming) { delta in
            NameSheet(delta: delta, module: module) { name, note in
                Task { await record(delta, name: name, note: note) }
            }
        }
    }

    // MARK: - Module

    private var modulePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("MODULE")
            Picker("Module", selection: $module) {
                ForEach(registry?.modules ?? []) { entry in
                    Text("\(entry.label) · \(entry.name)").tag(entry.address)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.copper)
            .disabled(phase == .capturingBaseline || phase == .capturingChange)

            if let entry = registry?.module(at: module) {
                Text("\(entry.identifiersAnswering) identifiers answer · pages \(entry.pages.joined(separator: " "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("CAPTURE")

            stepRow(
                number: 1,
                title: "Baseline",
                detail: "Leave the car as it is. This is what everything gets compared against.",
                done: baseline != nil
            ) {
                TextField("state, e.g. \"gate closed\"", text: $baselineTag)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(baseline == nil ? "Capture baseline" : "Re-capture") {
                    Task { await capture(isBaseline: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.copper)
                .disabled(phase == .capturingBaseline || phase == .capturingChange)
            }

            stepRow(
                number: 2,
                title: "Change one thing",
                detail: "Open the tailgate. Fasten a belt. One thing — two at once and you can't tell which byte belonged to which.",
                done: phase == .results
            ) {
                TextField("state, e.g. \"gate open\"", text: $changedTag)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Capture and compare") {
                    Task { await capture(isBaseline: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.copper)
                .disabled(baseline == nil || phase == .capturingBaseline || phase == .capturingChange)
            }

            if !progress.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text(progress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stepRow<Content: View>(
        number: Int, title: String, detail: String, done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Theme.copper : Theme.background)
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.background)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    // MARK: - Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("WHAT MOVED")
            if deltas.isEmpty {
                Text("""
                Nothing moved.

                Either this signal isn't on this module, or it moved on its own \
                during both captures and was filtered out as noise. Try another \
                module, or a bigger change.
                """)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tap one to name it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                ForEach(deltas, id: \.did) { delta in
                    Button { naming = delta } label: { deltaRow(delta) }
                        .buttonStyle(.plain)
                }
                if deltas.count > 1 {
                    Text("""
                    \(deltas.count) moved together, so this doesn't yet say which \
                    is which. Change something *else* that should affect only one \
                    of them — that's what separated the rear gate from "any \
                    opening".
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.copper)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func deltaRow(_ delta: DIDDelta) -> some View {
        let known = registry?.signal(delta.did)?.signal
        let mine = recorded[String(format: "%03X:%04X", delta.module, delta.did)]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "22 %04X", delta.did))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text("\(delta.before?.hexString ?? "—")  →  \(delta.after?.hexString ?? "—")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.copper)
                if let mine {
                    Text(mine).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.copper)
                } else if let known, known.confidence == .confirmed {
                    Text("already known: \(known.name)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer()
            Image(systemName: mine == nil ? "tag" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(mine == nil ? Theme.textDim : Theme.copper)
        }
        .padding(10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Theme.redline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.redline.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(Theme.textDim)
    }

    // MARK: - Work

    private func capture(isBaseline: Bool) async {
        failure = nil
        phase = isBaseline ? .capturingBaseline : .capturingChange
        progress = "enumerating \(String(format: "%03X", module))…"

        let pages = registry?.module(at: module)?.pages.compactMap { UInt8($0, radix: 16) }
            ?? [0x01, 0x02, 0x10, 0x11]

        do {
            let snapshot = try await model.enumerate(
                module: module,
                pages: pages,
                tag: isBaseline ? baselineTag : changedTag
            )
            if isBaseline {
                baseline = snapshot
                deltas = []
                phase = .ready
                progress = ""
            } else {
                current = snapshot
                deltas = baseline.map { DIDScan.diff(from: $0, to: snapshot) } ?? []
                phase = .results
                progress = ""
            }
        } catch {
            failure = "Capture failed: \(error)"
            phase = baseline == nil ? .idle : .ready
            progress = ""
        }
    }

    private func record(_ delta: DIDDelta, name: String, note: String?) async {
        guard let findingStore, !name.isEmpty else { return }
        let finding = Finding(
            did: delta.did,
            module: delta.module,
            name: name,
            observedIn: [baselineTag, changedTag].filter { !$0.isEmpty },
            before: delta.before?.hexString,
            after: delta.after?.hexString,
            reverted: false,
            note: note
        )
        await findingStore.record(finding)
        recorded[String(format: "%03X:%04X", delta.module, delta.did)] = name
    }
}

// MARK: - Naming

private struct NameSheet: View {
    let delta: DIDDelta
    let module: UInt32
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(format: "22 %04X on module %03X", delta.did, delta.module))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    Text("\(delta.before?.hexString ?? "—")  →  \(delta.after?.hexString ?? "—")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Section("What is it?") {
                    TextField("e.g. Rear gate, Door RL, Belt driver", text: $name)
                }
                Section("Note") {
                    TextField("anything that would help later", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Text("""
                    This is recorded as *yours*, not as fact. Change it back and \
                    capture again to prove it tracks — a signal that moves once \
                    is a coincidence, one that moves and returns is a measurement.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Name this signal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

extension DIDDelta: Identifiable {
    public var id: UInt16 { did }
}
