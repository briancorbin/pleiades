import Maia
import Sterope
import SwiftUI

/// The car's own alerts, and what we do about them.
///
/// Distinct from the Alerts tab on purpose. There, we author thresholds and
/// own the resulting alert. Here, the car has already decided to make a
/// noise and the only question is what happens to it — pass through, quiet,
/// mute, or replace with something of ours.
public struct ChimesView: View {
    @ObservedObject var model: TelemetryModel
    let store: ChimePolicyStore

    @State private var policies: [String: ChimePolicy] = [:]
    @State private var installed: Set<InterceptionPoint> = []
    @State private var editing: Chime?
    @AppStorage("alcyone.haulingMode") private var haulingMode = false

    public init(model: TelemetryModel, store: ChimePolicyStore) {
        self.model = model
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                capabilityCard
                if model.gateOpen {
                    haulingCard
                }
                ForEach(Chime.foresterChimes) { chime in
                    chimeCard(chime)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task { await refresh() }
        .sheet(item: $editing) { chime in
            ChimeEditorView(
                chime: chime,
                policy: policies[chime.id] ?? ChimePolicy(id: chime.id),
                model: model
            ) { saved in
                policies[saved.id] = saved
                Task { await store.save(saved) }
            }
        }
    }

    private func refresh() async {
        let all = await store.all()
        policies = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        installed = await store.installedPoints()
    }

    private var header: some View {
        HStack {
            Text("FACTORY CHIMES")
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.text)
            Text("🔔")
                .font(.system(size: 11))
            Spacer()
            let changed = policies.values.filter { $0.action != .passthrough }.count
            Text(changed == 0 ? "all stock" : "\(changed) modified")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(changed == 0 ? Theme.textDim : Theme.copper)
        }
    }

    /// Which interception hardware is actually installed. A policy can be
    /// set before the hardware exists; whether it's *enforced* is a separate
    /// fact, and pretending otherwise would be the one thing worse than not
    /// having the feature.
    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(Theme.copper)
                Text("INTERCEPTION HARDWARE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.copper)
                Spacer()
                Text(installed.isEmpty ? "none installed" : "\(installed.count) installed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(installed.isEmpty ? Theme.textDim : Theme.copper)
            }
            ForEach(InterceptionPoint.allCases, id: \.self) { point in
                Toggle(isOn: binding(for: point)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(point.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(pointDetail(point))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .tint(Theme.copper)
            }
            if installed.isEmpty {
                Text("Nothing is installed yet, so policies below are recorded but not enforced. Set what you want now — it takes effect when the hardware lands.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(14)
        .background(Theme.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pointDetail(_ point: InterceptionPoint) -> String {
        switch point {
        case .inputDiscrete: return "Relays on discrete signal wires (SHED-95)"
        case .inputCAN: return "Transparent CAN gateway — rewrite in transit (SHED-95)"
        case .output: return "Cluster speaker tap — mute and substitute (SHED-79)"
        }
    }

    private func binding(for point: InterceptionPoint) -> Binding<Bool> {
        Binding(
            get: { installed.contains(point) },
            set: { on in
                if on { installed.insert(point) } else { installed.remove(point) }
                let snapshot = installed
                Task { await store.setInstalled(snapshot) }
            }
        )
    }

    private var haulingCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Theme.copper)
            VStack(alignment: .leading, spacing: 2) {
                Text("HAULING MODE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.copper)
                Text("Temporary override for this trip — the gate is open on purpose. Crack a window: exhaust can draw into the cabin.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Toggle("", isOn: $haulingMode)
                .labelsHidden()
                .tint(Theme.copper)
        }
        .padding(14)
        .background(Theme.copper.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func chimeCard(_ chime: Chime) -> some View {
        let policy = policies[chime.id] ?? ChimePolicy(id: chime.id)
        let modified = policy.action != .passthrough
        let firing = isFiring(chime)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName(policy.action))
                    .font(.system(size: 15))
                    .foregroundStyle(modified ? Theme.copper : Theme.textDim)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(chime.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        if firing {
                            Text("ACTIVE NOW")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.redline)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.redline.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(chime.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text(policy.action.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(modified ? Theme.copper : Theme.textDim)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 6) {
                Image(systemName: enforced(chime, policy) ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 9))
                Text(enforced(chime, policy)
                     ? policy.action.effect
                     : (policy.action == .passthrough
                        ? chime.reach.describedReach
                        : "not enforced — needs \(neededHardware(chime, policy))"))
                    .font(.system(size: 10))
            }
            .foregroundStyle(enforced(chime, policy) ? Theme.copper : Theme.textDim)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { editing = chime }
    }

    /// True when the condition this chime reacts to is live right now — the
    /// CAN state hint the interception board will use to tell chimes apart.
    private func isFiring(_ chime: Chime) -> Bool {
        guard let ref = chime.signal else { return false }
        guard let value = model.proprietary[ref.id] else { return false }
        // Latches fire when open; the belt chime fires when *un*buckled.
        return chime.id == "seatbelt" ? value < 0.5 : value > 0.5
    }

    /// A policy only does something if the hardware it needs is installed
    /// *and* this chime can be reached that way.
    private func enforced(_ chime: Chime, _ policy: ChimePolicy) -> Bool {
        guard policy.action != .passthrough else { return false }
        let usable = chime.points.intersection(installed)
        return !policy.action.requiredPoints.isDisjoint(with: usable)
    }

    private func neededHardware(_ chime: Chime, _ policy: ChimePolicy) -> String {
        let candidates = policy.action.requiredPoints.intersection(chime.points)
        return candidates.map(\.displayName).sorted().joined(separator: " or ")
    }

    private func iconName(_ action: ChimeAction) -> String {
        switch action {
        case .passthrough: return "speaker.wave.2"
        case .prevent: return "hand.raised.fill"
        case .quieter: return "speaker.wave.1"
        case .muted: return "speaker.slash"
        case .replaced: return "waveform"
        }
    }
}

/// Per-chime policy editor.
struct ChimeEditorView: View {
    let chime: Chime
    @State var policy: ChimePolicy
    @ObservedObject var model: TelemetryModel
    let onSave: (ChimePolicy) -> Void

    @Environment(\.dismiss) private var dismiss

    private var soundOptions: [AlertSound] {
        AlertSound.allBuiltIns + AlertSoundLibrary.customSounds()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chime.name.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.text)
                Text(chime.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHEN THE CAR SOUNDS THIS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textDim)
                Picker("", selection: $policy.action) {
                    ForEach(chime.availableActions(), id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(policy.action.effect)
                    .font(.system(size: 11))
                    .foregroundStyle(policy.action == .prevent ? Theme.copper : Theme.textDim)
                if !chime.points.contains(where: { $0.isInput }) {
                    Text("This chime has no input we can reach, so it can only be handled at the speaker.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                }
            }

            if policy.action == .replaced {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PLAY INSTEAD")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textDim)
                    HStack(spacing: 10) {
                        Picker("", selection: $policy.sound) {
                            ForEach(soundOptions, id: \.self) { sound in
                                Text(sound.displayName).tag(sound)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.copper)
                        .labelsHidden()
                        Button {
                            model.preview(policy.sound, volume: policy.volume)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(policy.sound == .silent)
                    }
                }
            }

            if policy.action == .quieter || policy.action == .replaced {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VOLUME")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textDim)
                    HStack(spacing: 10) {
                        Slider(value: $policy.volume, in: 0...1)
                            .tint(Theme.copper)
                        Text("\(Int(policy.volume * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Reachable via: \(chime.reach.describedReach)")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Theme.textDim)

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    onSave(policy)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.copper)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
