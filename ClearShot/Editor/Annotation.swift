import AppKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, text, counter, marker, pen, redact, spotlight, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .counter: "Counter"
        case .marker: "Highlighter"
        case .pen: "Pen"
        case .redact: "Blur"
        case .spotlight: "Spotlight"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .counter: "1.circle"
        case .marker: "highlighter"
        case .pen: "scribble"
        case .redact: "drop.halffull"
        case .spotlight: "light.max"
        case .crop: "crop"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .counter: "n"
        case .marker: "h"
        case .pen: "p"
        case .redact: "b"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .text: .text
        case .counter: .counter
        case .marker: .marker
        case .pen: .pen
        case .redact: .redact
        case .spotlight: .spotlight
        case .select, .crop: nil
        }
    }

    var usesColor: Bool {
        switch self {
        case .redact, .spotlight, .crop, .select: false
        default: true
        }
    }

    var usesSize: Bool {
        switch self {
        case .redact, .spotlight, .crop, .select: false
        default: true
        }
    }
}

/// sRGB color with alpha, Codable for the annotation document.
nonisolated struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(oklch l: Double, _ c: Double, _ h: Double) {
        let rgb = OKLCH.srgb(l, c, h)
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Relative luminance, used to pick legible ink on top of this color.
    var isLight: Bool { 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 }

    static let palette: [(name: String, color: RGBA)] = [
        ("Red", RGBA(oklch: 0.63, 0.23, 27)),
        ("Orange", RGBA(oklch: 0.74, 0.18, 55)),
        ("Yellow", RGBA(oklch: 0.88, 0.17, 95)),
        ("Green", RGBA(oklch: 0.7, 0.18, 148)),
        ("Blue", RGBA(oklch: 0.6, 0.2, 258)),
        ("Purple", RGBA(oklch: 0.58, 0.22, 300)),
        ("Black", RGBA(oklch: 0.2, 0.01, 262)),
        ("White", RGBA(oklch: 0.985, 0.003, 262)),
    ]
}

nonisolated enum RedactStyle: String, Codable, CaseIterable {
    case pixelate, blur

    var label: String { self == .pixelate ? "Pixelate" : "Blur" }
}

nonisolated enum TextStyleKind: String, Codable, CaseIterable {
    case plain, filled

    var label: String { self == .plain ? "Plain" : "Filled" }
}

nonisolated struct Annotation: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case arrow, line, rectangle, ellipse, text, counter, marker, pen, redact, spotlight
    }

    var id = UUID()
    var kind: Kind
    /// Image pixel coordinates, origin top-left.
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA
    /// Stroke width (or text size / counter radius basis) in image pixels.
    var size: CGFloat
    var filled = false
    var text = ""
    var number = 0
    var redactStyle: RedactStyle = .pixelate
    var textStyle: TextStyleKind = .plain

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isRectLike: Bool {
        kind == .rectangle || kind == .ellipse || kind == .redact || kind == .spotlight
    }

    var fontSize: CGFloat { size * 4.2 }
    var counterRadius: CGFloat { max(size * 2.6, 12) }

    var textPadding: CGSize {
        textStyle == .filled ? CGSize(width: fontSize * 0.42, height: fontSize * 0.22) : .zero
    }

    /// Measured text block including padding; text is anchored at `start` (top-left).
    var textFrame: CGRect {
        let display = text.isEmpty ? " " : text
        let font = Jakarta.nsFont(fontSize, .bold)
        let bounds = NSAttributedString(string: display, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = textPadding
        return CGRect(x: start.x, y: start.y, width: ceil(bounds.width) + pad.width * 2 + 2, height: ceil(bounds.height) + pad.height * 2)
    }

    /// Bounds used for selection outlines and hit-testing slack.
    var bounds: CGRect {
        switch kind {
        case .text: return textFrame
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .pen, .marker:
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            return box
        default:
            return rect
        }
    }

    mutating func offset(by delta: CGSize) {
        start.x += delta.width; start.y += delta.height
        end.x += delta.width; end.y += delta.height
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }
}

// MARK: - Background

struct BackgroundPreset: Identifiable {
    let id: Int
    let name: String
    let colors: [RGBA]

    var gradient: LinearGradient {
        LinearGradient(colors: colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let all: [BackgroundPreset] = [
        BackgroundPreset(id: 0, name: "Dusk", colors: [RGBA(oklch: 0.74, 0.12, 262), RGBA(oklch: 0.66, 0.15, 318)]),
        BackgroundPreset(id: 1, name: "Ember", colors: [RGBA(oklch: 0.82, 0.12, 70), RGBA(oklch: 0.66, 0.18, 30)]),
        BackgroundPreset(id: 2, name: "Moss", colors: [RGBA(oklch: 0.84, 0.09, 140), RGBA(oklch: 0.62, 0.1, 190)]),
        BackgroundPreset(id: 3, name: "Sky", colors: [RGBA(oklch: 0.9, 0.06, 220), RGBA(oklch: 0.72, 0.12, 250)]),
        BackgroundPreset(id: 4, name: "Sand", colors: [RGBA(oklch: 0.95, 0.03, 85), RGBA(oklch: 0.86, 0.05, 60)]),
        BackgroundPreset(id: 5, name: "Ink", colors: [RGBA(oklch: 0.3, 0.03, 262), RGBA(oklch: 0.18, 0.02, 280)]),
        BackgroundPreset(id: 6, name: "Paper", colors: [RGBA(oklch: 0.975, 0.004, 90), RGBA(oklch: 0.955, 0.006, 90)]),
        BackgroundPreset(id: 7, name: "Graphite", colors: [RGBA(oklch: 0.5, 0.01, 262), RGBA(oklch: 0.36, 0.01, 262)]),
    ]
}

nonisolated enum BackgroundAspect: String, Codable, CaseIterable {
    case auto, square, wide, standard

    var label: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .wide: "16:9"
        case .standard: "4:3"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .wide: 16 / 9
        case .standard: 4 / 3
        }
    }
}

nonisolated struct BackgroundSettings: Codable, Equatable {
    var enabled = false
    var preset = 0
    /// Padding in points; multiplied by the capture's scale when rendering.
    var padding: Double = 56
    var cornerRadius: Double = 12
    var shadow: Double = 0.6
    var aspect: BackgroundAspect = .auto
}

nonisolated struct EditorDocument: Codable, Equatable {
    var annotations: [Annotation] = []
    /// Crop in image pixel coordinates.
    var crop: CGRect?
    var background = BackgroundSettings()
}
