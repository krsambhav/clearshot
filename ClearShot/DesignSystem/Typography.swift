import AppKit
import CoreText
import SwiftUI

/// Plus Jakarta Sans, bundled as static instances so every weight renders exactly as drawn.
nonisolated enum Jakarta {
    enum Weight {
        case regular, medium, semibold, bold, extrabold

        var postScriptName: String {
            switch self {
            case .regular: "PlusJakartaSans-Regular"
            case .medium: "PlusJakartaSans-Medium"
            case .semibold: "PlusJakartaSans-SemiBold"
            case .bold: "PlusJakartaSans-Bold"
            case .extrabold: "PlusJakartaSans-ExtraBold"
            }
        }

        var system: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .extrabold: .heavy
            }
        }
    }

    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        let fonts = urls.filter { $0.lastPathComponent.hasPrefix("PlusJakartaSans") }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    /// AppKit font for layers and attributed strings. Digits are tabular so sizes don't jitter.
    static func nsFont(_ size: CGFloat, _ weight: Weight = .regular, tabular: Bool = false) -> NSFont {
        let base = NSFont(name: weight.postScriptName, size: size) ?? .systemFont(ofSize: size, weight: weight.system)
        guard tabular else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

extension Font {
    static func jakarta(_ size: CGFloat, _ weight: Jakarta.Weight = .regular) -> Font {
        .custom(weight.postScriptName, fixedSize: size)
    }
}

/// App UI type scale (fixed, ~1.2 ratio at the small end where mac UI lives).
enum TextStyle {
    case caption, footnote, body, bodyStrong, label, title3, title2, title1, display

    var size: CGFloat {
        switch self {
        case .caption: 11
        case .footnote: 12
        case .body, .bodyStrong, .label: 13
        case .title3: 15
        case .title2: 19
        case .title1: 24
        case .display: 30
        }
    }

    var weight: Jakarta.Weight {
        switch self {
        case .caption, .footnote, .body: .regular
        case .label: .medium
        case .bodyStrong, .title3: .semibold
        case .title2, .title1: .bold
        case .display: .extrabold
        }
    }

    var tracking: CGFloat {
        switch self {
        case .title1, .display: -0.4
        case .title2: -0.2
        case .caption: 0.1
        default: 0
        }
    }
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(.jakarta(style.size, style.weight)).tracking(style.tracking)
    }
}
