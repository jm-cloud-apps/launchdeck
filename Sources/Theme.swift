import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = (value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        case 3:
            (r, g, b) = ((value >> 8 & 0xF) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// The iOS dark palette, so the deck reads like a Settings / App Store
/// screen rather than a terminal: black grouped background, #1c1c1e cards,
/// system blue/green/red/orange for state, secondary labels at 60%.
enum IOS {
    static let background = Color(hex: "000000")
    static let card       = Color(hex: "1c1c1e")
    static let fill       = Color(hex: "2c2c2e")     // tertiary fill: pills, tracks
    static let separator  = Color.white.opacity(0.12)
    static let label      = Color.white
    static let secondary  = Color(hex: "ebebf5").opacity(0.6)
    static let tertiary   = Color(hex: "ebebf5").opacity(0.3)
    static let blue   = Color(hex: "0a84ff")
    static let green  = Color(hex: "30d158")
    static let red    = Color(hex: "ff453a")
    static let orange = Color(hex: "ff9f0a")
    static let purple = Color(hex: "bf5af2")
    static let gray   = Color(hex: "8e8e93")
}

/// The App Store "GET" pill: capsule of tertiary fill with bold coloured text.
struct PillButton: ButtonStyle {
    var tint: Color = IOS.blue
    var width: CGFloat? = 72

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(tint)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(width: width)
            .background(Capsule().fill(IOS.fill))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A round secondary-action button (the iOS "ⓘ" / "•••" shape).
struct CircleButton: ButtonStyle {
    var tint: Color = IOS.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(IOS.fill))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Circle())
    }
}
