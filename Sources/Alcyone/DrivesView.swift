import Celaeno
import SwiftUI

/// Recorded drives: start/stop recording, browse past sessions, chart any
/// signal over a whole drive.
public struct DrivesView: View {
    @ObservedObject var model: TelemetryModel

    @State private var sessions: [DriveSession] = []
    @State private var expandedSession: UUID?

    public init(model: TelemetryModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                recordCard
                if sessions.isEmpty {
                    emptyCard
                } else {
                    ForEach(sessions) { session in
                        sessionCard(session)
                    }
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        sessions = await model.driveStore.list()
    }

    private var recordCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isRecording ? Theme.redline : Theme.textDim)
                .frame(width: 10, height: 10)
            Text(model.isRecording ? "RECORDING DRIVE" : "NOT RECORDING")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(model.isRecording ? Theme.redline : Theme.textDim)
            Spacer()
            Button(model.isRecording ? "Stop" : "Start recording") {
                Task {
                    if model.isRecording {
                        await model.stopRecording()
                    } else {
                        await model.startRecording()
                    }
                    await refresh()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? Theme.redline : Theme.copper)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "road.lanes.curved.right")
                .foregroundStyle(Theme.textDim)
            Text("No recorded drives yet — hit record and take the fake car for a spin.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sessionCard(_ session: DriveSession) -> some View {
        let expanded = expandedSession == session.id
        return VStack(alignment: .leading, spacing: 10) {
            sessionHeader(session, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedSession = expanded ? nil : session.id
                    }
                }
            if expanded {
                sessionDetail(session)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sessionHeader(_ session: DriveSession, expanded: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "car.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.copper)
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Spacer()
            Text(durationText(session.duration))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.copper)
            Text("\(session.samples.count) samples")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func sessionDetail(_ session: DriveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WindowChartView(
                window: session.samples.map { WindowSample(t: $0.t, pid: $0.pid, value: $0.value) },
                title: "DRIVE",
                subtitle: "from start of recording",
                showTriggerRule: false,
                xLabel: "seconds into drive"
            )
            HStack {
                Spacer()
                Button("Delete drive", role: .destructive) {
                    Task {
                        await model.driveStore.delete(session.id)
                        await refresh()
                    }
                }
                .buttonStyle(.bordered)
                .tint(Theme.redline)
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
