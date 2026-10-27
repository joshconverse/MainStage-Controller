import SwiftUI
import FOHCore

/// Design tokens from the design canvas (dark FOH theme).
enum Theme {
    static let ground = Color(hex: 0x0B0C0E)
    static let panel = Color(hex: 0x141619)
    static let raised = Color(hex: 0x1C1F23)
    static let raised2 = Color(hex: 0x24282D)
    static let line = Color(hex: 0x2C3036)
    static let text = Color(hex: 0xECEEF1)
    static let text2 = Color(hex: 0xA3A9B1)
    static let text3 = Color(hex: 0x858C95)

    static let eq = Color(hex: 0xF5A524)
    static let dynamics = Color(hex: 0x4C9EFF)
    static let sends = Color(hex: 0x2DD4BF)
    static let inserts = Color(hex: 0xA78BFA)
    static let mute = Color(hex: 0xE5484D)
    static let solo = Color(hex: 0xF5D90A)
    static let meterGreen = Color(hex: 0x3DD68C)
    static let meterYellow = Color(hex: 0xF5D90A)
    static let meterRed = Color(hex: 0xFF5C5C)
    static let faderCap = Color(hex: 0xD9DCE0)

    static func channel(_ c: ChannelColor) -> Color {
        switch c {
        case .red: return Color(hex: 0xFF6B6B)
        case .green: return Color(hex: 0x4ADE80)
        case .yellow: return Color(hex: 0xFACC15)
        case .blue: return Color(hex: 0x60A5FA)
        case .magenta: return Color(hex: 0xE879F9)
        case .cyan: return Color(hex: 0x22D3EE)
        case .white: return Color(hex: 0xE5E7EB)
        case .off: return Color(hex: 0x3A3F46)
        }
    }

    static func channelText(_ c: ChannelColor) -> Color { c == .off ? Color(hex: 0xD5D8DC) : ground }

    static let label = Font.system(size: 10, weight: .bold)
    static let mono = Font.system(size: 12, weight: .semibold).monospacedDigit()
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Small uppercase section label ("LAYERS", "SENDS").
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1)
            .foregroundStyle(Theme.text3)
    }
}
