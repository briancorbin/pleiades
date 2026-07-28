import SwiftUI

/// Classic 270°-sweep round gauge: dim track, copper fill, white needle,
/// optional redline zone.
public struct RadialGauge: View {
    let label: String
    let unit: String
    let value: Double
    let range: ClosedRange<Double>
    let redlineFrom: Double?
    let displayValue: String

    public init(
        label: String,
        unit: String,
        value: Double,
        range: ClosedRange<Double>,
        redlineFrom: Double? = nil,
        displayValue: String? = nil
    ) {
        self.label = label
        self.unit = unit
        self.value = value
        self.range = range
        self.redlineFrom = redlineFrom
        self.displayValue = displayValue ?? String(format: "%.0f", value)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func fraction(of v: Double) -> Double {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                arcs(side: side)
                ticks(side: side)
                needle(side: side)
                centerLabels(side: side)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: value)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arcs(side: CGFloat) -> some View {
        let lineWidth: CGFloat = side * 0.055
        return ZStack {
            trackArc(lineWidth: lineWidth)
            redlineArc(lineWidth: lineWidth)
            fillArc(lineWidth: lineWidth)
        }
    }

    private func trackArc(lineWidth: CGFloat) -> some View {
        GaugeArc(from: 0, to: 1)
            .stroke(Theme.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    @ViewBuilder
    private func redlineArc(lineWidth: CGFloat) -> some View {
        if let redlineFrom {
            GaugeArc(from: fraction(of: redlineFrom), to: 1)
                .stroke(Theme.redline.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
    }

    private func fillArc(lineWidth: CGFloat) -> some View {
        let gradient = AngularGradient(
            colors: [Theme.copperDim, Theme.copper],
            center: .center,
            startAngle: .degrees(135),
            endAngle: .degrees(405)
        )
        return GaugeArc(from: 0, to: fraction)
            .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func centerLabels(side: CGFloat) -> some View {
        let spacing: CGFloat = side * 0.01
        let valueSize: CGFloat = side * 0.17
        let unitSize: CGFloat = side * 0.06
        let labelSize: CGFloat = side * 0.05
        let offsetY: CGFloat = side * 0.10
        return VStack(spacing: spacing) {
            Text(displayValue)
                .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(unit)
                .font(.system(size: unitSize, weight: .medium))
                .foregroundStyle(Theme.copper)
            Text(label.uppercased())
                .font(.system(size: labelSize, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textDim)
        }
        .offset(y: offsetY)
    }

    private func ticks(side: CGFloat) -> some View {
        ForEach(0..<11) { i in
            tick(index: i, side: side)
        }
    }

    private func tick(index: Int, side: CGFloat) -> some View {
        let isMajor = index % 5 == 0
        let width: CGFloat = side * 0.008
        let height: CGFloat = side * (isMajor ? 0.05 : 0.03)
        let offsetY: CGFloat = side * -0.40
        let angle: Double = -135 + Double(index) * 27
        return Rectangle()
            .fill(isMajor ? Theme.textDim : Theme.track)
            .frame(width: width, height: height)
            .offset(y: offsetY)
            .rotationEffect(.degrees(angle))
    }

    private func needle(side: CGFloat) -> some View {
        let width: CGFloat = side * 0.014
        let height: CGFloat = side * 0.32
        let offsetY: CGFloat = side * -0.16
        let angle: Double = -135 + fraction * 270
        return Capsule()
            .fill(Color.white)
            .frame(width: width, height: height)
            .offset(y: offsetY)
            .rotationEffect(.degrees(angle))
            .shadow(color: Theme.copper.opacity(0.6), radius: 4)
    }
}

/// Arc over the gauge's 270° sweep; fraction 0 starts at 7:30, 1 ends at 4:30.
private struct GaugeArc: Shape {
    let from: Double
    let to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - 8
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(135 + 270 * min(max(from, 0), 1)),
            endAngle: .degrees(135 + 270 * min(max(to, 0), 1)),
            clockwise: false
        )
        return path
    }
}

/// Horizontal temperature-style bar with a warning zone.
public struct BarGauge: View {
    let label: String
    let unit: String
    let value: Double?
    let range: ClosedRange<Double>
    let warnAbove: Double
    let format: (Double) -> String

    public init(
        label: String,
        unit: String,
        value: Double?,
        range: ClosedRange<Double>,
        warnAbove: Double,
        format: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.label = label
        self.unit = unit
        self.value = value
        self.range = range
        self.warnAbove = warnAbove
        self.format = format
    }

    private var fraction: Double {
        guard let value else { return 0 }
        let span = range.upperBound - range.lowerBound
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var isWarning: Bool {
        (value ?? -.infinity) >= warnAbove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text(value.map(format) ?? "––")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isWarning ? Theme.redline : Theme.text)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.copper)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(isWarning ? Theme.redline : Theme.copper)
                        .frame(width: max(geo.size.width * fraction, 8))
                        .animation(.linear(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Small numeric readout tile.
public struct StatTile: View {
    let label: String
    let unit: String
    let text: String

    public init(label: String, unit: String, value: Double?, format: String = "%.0f") {
        self.label = label
        self.unit = unit
        self.text = value.map { String(format: format, $0) } ?? "––"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textDim)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.copper)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
