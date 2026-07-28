import Electra
import Sterope
import SwiftUI

/// Which car Alcyone talks to.
public enum TelemetrySourceKind: String, CaseIterable, Sendable {
    case electra
    case dongle

    public var displayName: String {
        switch self {
        case .electra: return "Electra · simulated car"
        case .dongle: return "OBD dongle · BLE"
        }
    }

    /// The dongle option needs CoreBluetooth permission plumbing that only
    /// the iOS shell has (usage string in Info.plist); the macOS bench
    /// stays Electra-only for now.
    public static var available: [TelemetrySourceKind] {
        #if os(iOS)
        return [.electra, .dongle]
        #else
        return [.electra]
        #endif
    }
}

/// Owns the model for one source selection. Shells recreate this view
/// (via .id) when the selection changes — fresh source, fresh model.
public struct SourceHostView: View {
    @StateObject private var model: TelemetryModel
    @Binding private var selection: String
    private let bench: ElectraSource?
    private let ruleStore: RuleStore

    public init(kind: TelemetrySourceKind, selection: Binding<String>, ruleStore: RuleStore) {
        _selection = selection
        self.ruleStore = ruleStore

        #if os(iOS)
        if kind == .dongle {
            let source = DongleSource()
            source.connect()
            bench = nil
            _model = StateObject(wrappedValue: TelemetryModel(source: source, ruleStore: ruleStore))
            return
        }
        #endif
        let source = ElectraSource()
        bench = source
        _model = StateObject(wrappedValue: TelemetryModel(source: source, ruleStore: ruleStore))
    }

    public var body: some View {
        RootView(model: model, bench: bench, ruleStore: ruleStore, sourceSelection: $selection)
            .onAppear { model.start() }
    }
}
