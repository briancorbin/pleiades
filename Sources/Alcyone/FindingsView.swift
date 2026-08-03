import Celaeno
import SwiftUI

/// What you've named, and the way it gets out of the phone.
///
/// Without this the Discover tab was a one-way door: you could sit in the car
/// naming five signals and have no way to see them again, let alone get them
/// into the registry. A finding trapped on a device is the same as a finding
/// nobody made.
///
/// Export is deliberately a text patch rather than an automatic registry
/// write. A name given in a driveway hasn't met the bar — measured, dated,
/// evidenced, and ideally seen to revert — and clearing that bar is a
/// judgement someone makes, not a file the app edits.
@MainActor
struct FindingsView: View {
    let store: FindingStore

    @Environment(\.dismiss) private var dismiss
    @State private var findings: [Finding] = []
    @State private var patch = ""
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if findings.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("Findings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !findings.isEmpty {
                        ShareLink(item: patch) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .confirmationDialog(
            "Delete every finding?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                Task {
                    await store.removeAll()
                    await reload()
                }
            }
        } message: {
            Text("Export them first — this can't be undone, and they only exist here.")
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag.slash")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textDim)
            Text("Nothing named yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Capture a baseline, change one thing, and tap whatever moved.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                These are yours, not registry facts. Export and paste into a \
                session to fold them in — a name given once still needs to be \
                seen changing back before it counts as measured.
                """)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(findings) { finding in
                    row(finding)
                }

                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Delete all findings", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .padding(.top, 8)
            }
            .padding(18)
        }
    }

    private func row(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(String(format: "22 %04X", finding.did))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(String(format: "@ %03X", finding.module))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text(finding.confidence)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(finding.reverted ? Theme.copper : Theme.textDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (finding.reverted ? Theme.copper : Theme.textDim).opacity(0.15),
                        in: Capsule()
                    )
            }
            Text(finding.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.copper)
            if let before = finding.before, let after = finding.after {
                Text("\(before) → \(after)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            if !finding.observedIn.isEmpty {
                Text(finding.observedIn.joined(separator: " → "))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim.opacity(0.8))
            }
            if let note = finding.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim.opacity(0.8))
            }
            if !finding.reverted {
                Text("Not yet seen to revert — change it back and re-capture to confirm.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    await store.remove(finding.id)
                    await reload()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func reload() async {
        findings = await store.all()
        patch = await store.exportPatch()
    }
}
