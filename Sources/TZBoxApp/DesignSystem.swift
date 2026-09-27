import AppKit
import SwiftUI

/// Warm, quiet surfaces with semantic text and explicit high-contrast boundaries.
enum TZStyle {
    static let smokeHighContrast = ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_OUTPUT"] != nil
        && ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_APPEARANCE"] == "contrast"
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive(0xF4F2ED, 0x202220)
    static let sidebar = adaptive(0xEDEBE5, 0x1B1D1B)
    static let surface = adaptive(0xF8F6F1, 0x2A2C29)
    static let inset = adaptive(0xEAE7DF, 0x1E211E)
    static let accent = adaptive(0xA5533B, 0xE4A58C)
    static let onAccent = adaptive(0xFFFFFF, 0x251C17)
    static let text = Color(nsColor: .labelColor)
    static let secondary = adaptive(0x62645D, 0xB7BBB1)
    static let line = adaptive(0xD7D5CC, 0x454A42)
    static let green = adaptive(0x36705B, 0x8BBEA5)
}

struct SoftSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = 16
    var recessed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if recessed {
                    shape.fill(TZStyle.inset
                        .shadow(.inner(color: .black.opacity(scheme == .dark ? 0.23 : 0.08), radius: 3, x: 2, y: 2))
                        .shadow(.inner(color: .white.opacity(scheme == .dark ? 0.035 : 0.75), radius: 2, x: -2, y: -2)))
                } else {
                    shape.fill(TZStyle.surface)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.055), radius: 9, x: 5, y: 6)
                        .shadow(color: .white.opacity(scheme == .dark ? 0.025 : 0.85), radius: 7, x: -4, y: -4)
                }
            }
            .overlay(shape.strokeBorder((contrast == .increased || TZStyle.smokeHighContrast) ? TZStyle.secondary : TZStyle.line.opacity(0.65),
                                        lineWidth: (contrast == .increased || TZStyle.smokeHighContrast) ? 1.2 : 0.6))
    }
}

extension View {
    func softSurface(radius: CGFloat = 16, recessed: Bool = false) -> some View {
        modifier(SoftSurface(radius: radius, recessed: recessed))
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(prominent ? TZStyle.onAccent : TZStyle.text)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? TZStyle.accent : (configuration.isPressed ? TZStyle.inset : TZStyle.surface))
                    .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.06), radius: 3, x: 1, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                (contrast == .increased || TZStyle.smokeHighContrast) ? TZStyle.secondary : TZStyle.line.opacity(prominent ? 0 : 0.8),
                lineWidth: (contrast == .increased || TZStyle.smokeHighContrast) ? 1.2 : 0.6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct BrandIcon: View {
    private var icon: NSImage? {
        Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(TZStyle.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .softSurface(radius: 12)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}
