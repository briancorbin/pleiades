import Maia
import SwiftUI

/// The tab that only exists because of Merope. Latches, belts, and per-wheel
/// tire pressures are on the car's own bus and unreachable by any OBD
/// request — when the source is a dongle this tab says so plainly rather
/// than showing empty gauges.
public struct VehicleView: View {
    @ObservedObject var model: TelemetryModel
    @AppStorage("alcyone.imperial") private var imperial = false
    @AppStorage("alcyone.haulingMode") private var haulingMode = false

    public init(model: TelemetryModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.hasProprietary {
                    if model.gateOpen {
                        gateCard
                    }
                    latchCard
                    tpmsCard
                    beltCard
                } else {
                    unavailableCard
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(Theme.textDim)
                Text("NO CAN TAP CONNECTED")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            Text("""
            Latch states, seatbelts and per-wheel tire pressures live on the \
            car's own CAN bus. No OBD request can retrieve them — a dongle has \
            nothing to ask. Connect Merope to see this page.
            """)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The origin story, as a feature.
    private var gateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "car.rear.and.tire.marks")
                    .font(.system(size: 18))
                    .foregroundStyle(haulingMode ? Theme.copper : Theme.redline)
                Text("REAR GATE OPEN")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(haulingMode ? Theme.copper : Theme.redline)
                Spacer()
                if haulingMode {
                    Text("HAULING")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.copper)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.copper.opacity(0.15), in: Capsule())
                }
            }
            Text(haulingMode
                 ? "Hauling mode is on for this trip. Keep the load strapped, and crack a window: exhaust can draw into the cabin through an open gate."
                 : "The car will chime about this. What happens to that chime is set on the Chimes tab.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        }
        .padding(16)
        .background((haulingMode ? Theme.copper : Theme.redline).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder((haulingMode ? Theme.copper : Theme.redline).opacity(0.5)))
    }

    private var latchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("LATCHES")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(ProprietarySignal.latches, id: \.id) { signal in
                    latchPill(signal)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func latchPill(_ signal: ProprietarySignal) -> some View {
        let open = (model.proprietaryValue(signal) ?? 0) > 0.5
        return VStack(spacing: 4) {
            Image(systemName: open ? "door.left.hand.open" : "door.left.hand.closed")
                .font(.system(size: 15))
                .foregroundStyle(open ? Theme.redline : Theme.textDim)
            Text(signal.name.replacingOccurrences(of: "Door ", with: ""))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Text(open ? "OPEN" : "shut")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(open ? Theme.redline : Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var beltCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SEATBELTS")
            HStack(spacing: 14) {
                beltPill(.beltDriver, label: "Driver")
                beltPill(.beltPassenger, label: "Passenger")
                Spacer()
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func beltPill(_ signal: ProprietarySignal, label: String) -> some View {
        let buckled = (model.proprietaryValue(signal) ?? 0) > 0.5
        return HStack(spacing: 6) {
            Image(systemName: buckled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(buckled ? Theme.copper : Theme.textDim)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.5), in: Capsule())
    }

    /// Per-corner pressures — the reason a Wilderness owner wants this page
    /// when airing down for a trail and back up after.
    private var tpmsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("TIRE PRESSURE")
                Spacer()
                Text(imperial ? "psi" : "kPa")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.copper)
            }
            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    tpmsCorner(.tpmsFrontLeft)
                    tpmsCorner(.tpmsRearLeft)
                }
                carOutline
                VStack(spacing: 12) {
                    tpmsCorner(.tpmsFrontRight)
                    tpmsCorner(.tpmsRearRight)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var carOutline: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.track, lineWidth: 2)
            .frame(width: 54, height: 110)
            .overlay(
                Image(systemName: "car.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.track)
            )
    }

    private func tpmsCorner(_ signal: ProprietarySignal) -> some View {
        let kPa = model.proprietaryValue(signal)
        let shown = kPa.map { imperial ? $0.kPaAsPSI : $0 }
        // ~193 kPa / 28 psi — below the placard pressure, worth noticing.
        let low = (kPa ?? 999) < 193
        return VStack(spacing: 2) {
            Text(shown.map { String(format: "%.0f", $0) } ?? "––")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(low ? Theme.redline : Theme.text)
            Text(signal.name.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(low ? Theme.redline.opacity(0.12) : Theme.background.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.textDim)
    }
}
