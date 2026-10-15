import AppKit
import SwiftUI

// MARK: - OKLCH

/// Converts OKLCH to gamma-encoded sRGB. All ClearShot colors are authored in OKLCH so
/// lightness steps look even across light and dark appearances.
nonisolated enum OKLCH {
    static func srgb(_ l: Double, _ c: Double, _ h: Double) -> (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let L = l_ * l_ * l_
        let M = m_ * m_ * m_
        let S = s_ * s_ * s_

        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S

        func encode(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (encode(r), encode(g), encode(bl))
    }
}

nonisolated extension NSColor {
    convenience init(oklch l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        let rgb = OKLCH.srgb(l, c, h)
        self.init(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Tokens

/// shadcn/ui (new-york, neutral) tokens, re-authored in OKLCH and tinted toward the brand hue.
nonisolated enum Theme {
    static let hue: Double = 262

    private static func tone(_ l: Double, _ c: Double = 0.004, alpha: Double = 1) -> NSColor {
        NSColor(oklch: l, c, hue, alpha: alpha)
    }

    private static func pair(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: .dynamic(light: light, dark: dark))
    }

    static let nsBackground = NSColor.dynamic(light: tone(0.993, 0.002), dark: tone(0.165, 0.006))
    static let nsCard = NSColor.dynamic(light: tone(0.998, 0.0015), dark: tone(0.195, 0.007))
    static let nsPopover = NSColor.dynamic(light: tone(0.998, 0.0015), dark: tone(0.21, 0.008))
    static let nsForeground = NSColor.dynamic(light: tone(0.17, 0.008), dark: tone(0.975, 0.003))
    static let nsBorder = NSColor.dynamic(light: tone(0.912, 0.005), dark: tone(0.97, 0.005, alpha: 0.1))

    static let background = Color(nsColor: nsBackground)
    static let card = Color(nsColor: nsCard)
    static let popover = Color(nsColor: nsPopover)
    static let foreground = Color(nsColor: nsForeground)

    static let primary = pair(tone(0.21, 0.008), tone(0.93, 0.004))
    static let primaryForeground = pair(tone(0.985, 0.002), tone(0.21, 0.008))

    static let secondary = pair(tone(0.962, 0.004), tone(0.265, 0.008))
    static let secondaryForeground = pair(tone(0.21, 0.008), tone(0.975, 0.003))

    static let muted = pair(tone(0.962, 0.004), tone(0.255, 0.008))
    static let mutedForeground = pair(tone(0.54, 0.012), tone(0.71, 0.012))

    static let accent = pair(tone(0.952, 0.005), tone(0.275, 0.009))
    static let accentForeground = pair(tone(0.21, 0.008), tone(0.975, 0.003))

    static let destructive = pair(NSColor(oklch: 0.577, 0.215, 27), NSColor(oklch: 0.66, 0.19, 23))
    static let success = pair(NSColor(oklch: 0.6, 0.15, 152), NSColor(oklch: 0.72, 0.15, 152))
    static let warning = pair(NSColor(oklch: 0.68, 0.15, 70), NSColor(oklch: 0.8, 0.14, 80))

    static let border = Color(nsColor: nsBorder)
    static let input = pair(tone(0.895, 0.006), tone(0.97, 0.005, alpha: 0.15))

    /// Brand signal. Reserved for selection, focus and the active tool.
    static let nsBrand = NSColor.dynamic(light: NSColor(oklch: 0.56, 0.2, hue), dark: NSColor(oklch: 0.66, 0.17, hue))
    static let brand = Color(nsColor: nsBrand)
    static let ring = brand.opacity(0.45)

    /// Overlay colors are appearance-independent: they sit on top of the user's pixels.
    static let scrim = NSColor(oklch: 0.12, 0.01, hue, alpha: 0.5)
    static let overlayInk = NSColor(oklch: 0.99, 0.002, hue)
    static let overlayChip = NSColor(oklch: 0.18, 0.01, hue, alpha: 0.88)
}

// MARK: - Spacing & radius (4pt grid)

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 14
}

// MARK: - Motion

enum Motion {
    /// Exponential-feeling deceleration, no overshoot.
    static let snappy = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.28)
    static let quick = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.16)
    static let gentle = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
}

// MARK: - Shadows

extension View {
    func shadowSm() -> some View {
        shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    func shadowMd() -> some View {
        shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    func shadowLg() -> some View {
        shadow(color: .black.opacity(0.1), radius: 6, y: 4)
            .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
    }
}
