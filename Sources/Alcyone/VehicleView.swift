import Maia
import SwiftUI

/// The state of the car as a thing you own, rather than an engine you're
/// watching: what's open, what's buckled, what the tires are at, how much
/// fuel is left.
///
/// This tab used to hide itself behind "no CAN tap connected", on the
/// premise that latches were unreachable by any OBD request. That premise
/// was wrong. Mode 22 asks the body integrated unit directly, and on
/// 2026-07-30 `22 104E` on module `0x75A` came back `FF` with the tailgate
/// open — through the dongle, no tap involved.
///
/// So nothing is gated on the source any more. Each reading shows what it
/// has, and says "—" when it has nothing, which is the honest answer whether
/// the cause is a missing tap, an identifier we haven't found yet, or a
/// module that just didn't answer this time.
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
                if model.gateOpen {
                    gateCard
                }
                vehicleCard
                latchCard
                beltCard
                tpmsCard
                if !model.hasProprietary {
                    bodySignalsNote
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    /// Standard OBD, available from any source — the numbers that describe
    /// the vehicle rather than the engine's current effort.
    private var vehicleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("VEHICLE")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 10
            ) {
                fact("Fuel", model.value(.fuelLevel), "%", digits: 0)
                fact("Battery", model.value(.controlModuleVoltage), "V", digits: 1)
                fact("Oil", temperature(model.value(.oilTemp)), temperatureUnit)
                fact("Coolant", temperature(model.value(.coolantTemp)), temperatureUnit)
                fact("Outside", temperature(model.value(.ambientAirTemp)), temperatureUnit)
                fact("Intake", temperature(model.value(.intakeAirTemp)), temperatureUnit)
                fact("Running", model.value(.runTime).map { $0 / 60 }, "min", digits: 0)
                fact("Since cleared", distance(model.value(.distanceSinceCleared)), distanceUnit, digits: 0)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fact(_ label: String, _ value: Double?, _ unit: String, digits: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.textDim)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.\(digits)f", $0) } ?? "—")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(value == nil ? Theme.textDim.opacity(0.5) : Theme.text)
                Text(value == nil ? "" : unit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func temperature(_ celsius: Double?) -> Double? {
        celsius.map { imperial ? Units.fahrenheit($0) : $0 }
    }

    private var temperatureUnit: String { imperial ? "°F" : "°C" }

    private func distance(_ km: Double?) -> Double? {
        km.map { imperial ? $0 * 0.621371 : $0 }
    }

    private var distanceUnit: String { imperial ? "mi" : "km" }

    /// Shown only when nothing on the body side answered at all — so it's a
    /// note about this session, not a claim that the data doesn't exist.
    private var bodySignalsNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(Theme.textDim)
                Text("NO BODY SIGNALS YET")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            Text("""
            Latches and belts come from the body integrated unit over mode 22, \
            which works through a dongle — but only for identifiers we've \
            found. The rear gate and front passenger door are confirmed; the \
            rest are still being mapped. Tire pressures need Merope.
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
        // Three states, not two. A signal we've never found on this car
        // returns nil, and rendering that as "shut" is a lie the size of an
        // open tailgate — it looks exactly like a door that's fine.
        let reading = model.proprietaryValue(signal)
        let open = (reading ?? 0) > 0.5
        let known = reading != nil
        let icon = !known ? "questionmark.circle"
            : (open ? "door.left.hand.open" : "door.left.hand.closed")
        let tint = !known ? Theme.textDim.opacity(0.5)
            : (open ? Theme.redline : Theme.textDim)

        return VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Text(signal.name.replacingOccurrences(of: "Door ", with: ""))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(known ? Theme.textDim : Theme.textDim.opacity(0.5))
            Text(!known ? "—" : (open ? "OPEN" : "shut"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
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
        // Same three states. An unbuckled belt and a belt we can't read are
        // very different things to show someone.
        let reading = model.proprietaryValue(signal)
        let buckled = (reading ?? 0) > 0.5
        let known = reading != nil
        return HStack(spacing: 6) {
            Image(systemName: !known ? "questionmark.circle"
                : (buckled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(!known ? Theme.textDim.opacity(0.5) : (buckled ? Theme.copper : Theme.textDim))
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
