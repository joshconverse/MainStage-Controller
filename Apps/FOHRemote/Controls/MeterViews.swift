import SwiftUI
import FOHCore

/// What a meter shows.
enum MeterTarget: Equatable {
    case strip(Strip)
    case master
}

/// One vertical meter: RMS solid, peak translucent above it, peak-hold line.
struct MeterBar: View {
    var level: MeterStore.Level
    var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Color(hex: 0x101215)
                // The gradient spans the full height and is masked, so colour reflects level, not bar length.
                Self.gradient.opacity(0.45).mask(alignment: .bottom) { Rectangle().frame(height: h * level.peak) }
                Self.gradient.mask(alignment: .bottom) { Rectangle().frame(height: h * level.rms) }
                if level.hold > 0.01 {
                    Rectangle().fill(level.hold > 0.95 ? Theme.meterRed : Theme.text.opacity(0.85))
                        .frame(height: 2)
                        .offset(y: -h * level.hold + 1)
                }
            }
            .frame(width: width, height: h, alignment: .bottom)
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    static let gradient = LinearGradient(stops: [.init(color: Theme.meterGreen, location: 0), .init(color: Theme.meterGreen, location: 0.68),
                                                 .init(color: Theme.meterYellow, location: 0.8), .init(color: Theme.meterRed, location: 0.95)],
                                         startPoint: .bottom, endPoint: .top)
}

/// Live meter for a strip or the master, reading `MeterStore` so only this view redraws at the meter rate.
struct LiveMeter: View {
    @Environment(MeterStore.self) private var meters
    @Environment(MixerStore.self) private var store
    let target: MeterTarget
    var barWidth: CGFloat? = nil

    var body: some View {
        let levels: [MeterStore.Level]? = {
            switch target {
            case .strip(let s): return meters.levels(for: s)
            case .master: return meters.masterLevels(store.config)
            }
        }()
        if let levels, !levels.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                    MeterBar(level: l, width: barWidth ?? (levels.count == 1 ? 8 : 4))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Meter")
            .accessibilityValue(levels.map { String(format: "%.0f dB", MeterScale.floorDB + $0.peak * -MeterScale.floorDB) }.joined(separator: ", "))
        } else {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: barWidth ?? 8)
                .accessibilityHidden(true)
        }
    }
}
