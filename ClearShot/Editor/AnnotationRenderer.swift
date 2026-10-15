import CoreImage
import SwiftUI

/// Pre-processed copies of the base image used by the redact tool.
struct EffectImages {
    var pixelated: CGImage?
    var blurred: CGImage?

    nonisolated static func make(from image: CGImage) -> EffectImages {
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let block = max(10, CGFloat(max(image.width, image.height)) / 90)

        let pixellate = CIFilter(name: "CIPixellate")
        pixellate?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        pixellate?.setValue(block, forKey: kCIInputScaleKey)
        pixellate?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)

        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur?.setValue(block * 1.4, forKey: kCIInputRadiusKey)

        return EffectImages(
            pixelated: pixellate?.outputImage.flatMap { context.createCGImage($0.cropped(to: extent), from: extent) },
            blurred: blur?.outputImage.flatMap { context.createCGImage($0.cropped(to: extent), from: extent) }
        )
    }
}

enum AnnotationRenderer {
    /// Draws annotations in image pixel space. `context` must already map pixels to the target.
    static func draw(
        _ annotations: [Annotation],
        in context: GraphicsContext,
        imageSize: CGSize,
        effects: EffectImages,
        pointScale: CGFloat,
        hidden: UUID? = nil
    ) {
        let full = CGRect(origin: .zero, size: imageSize)

        for annotation in annotations where annotation.kind == .redact && annotation.id != hidden {
            drawRedaction(annotation, in: context, full: full, effects: effects)
        }

        let spotlights = annotations.filter { $0.kind == .spotlight && $0.id != hidden }
        if !spotlights.isEmpty {
            var holes = Path()
            for spot in spotlights {
                holes.addRoundedRect(in: spot.rect, cornerSize: CGSize(width: 6 * pointScale, height: 6 * pointScale), style: .continuous)
            }
            var dim = context
            dim.clip(to: holes, options: .inverse)
            dim.fill(Path(full), with: .color(.black.opacity(0.55)))
        }

        for annotation in annotations where annotation.id != hidden {
            switch annotation.kind {
            case .redact, .spotlight: continue
            default: drawShape(annotation, in: context, pointScale: pointScale)
            }
        }
    }

    private static func drawRedaction(_ annotation: Annotation, in context: GraphicsContext, full: CGRect, effects: EffectImages) {
        let rect = annotation.rect
        guard rect.width > 0, rect.height > 0 else { return }
        var clipped = context
        clipped.clip(to: Path(rect))
        let source = annotation.redactStyle == .pixelate ? effects.pixelated : effects.blurred
        if let source {
            clipped.draw(Image(decorative: source, scale: 1), in: full)
        } else {
            clipped.fill(Path(rect), with: .color(.gray))
        }
    }

    private static func drawShape(_ a: Annotation, in base: GraphicsContext, pointScale: CGFloat) {
        var context = base
        let color = a.color.color
        let shadowRadius = 2.5 * pointScale
        if a.kind != .marker {
            context.addFilter(.shadow(color: .black.opacity(a.color.isLight ? 0.4 : 0.22), radius: shadowRadius, x: 0, y: 0.75 * pointScale))
        }

        switch a.kind {
        case .arrow:
            context.fill(arrowPath(from: a.start, to: a.end, width: a.size), with: .color(color))

        case .line:
            var path = Path()
            path.move(to: a.start)
            path.addLine(to: a.end)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: a.size, lineCap: .round))

        case .rectangle:
            let path = Path(roundedRect: a.rect, cornerRadius: a.filled ? a.size * 0.8 : a.size * 0.9, style: .continuous)
            if a.filled {
                context.fill(path, with: .color(color))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: a.size, lineJoin: .round))
            }

        case .ellipse:
            let path = Path(ellipseIn: a.rect)
            if a.filled {
                context.fill(path, with: .color(color))
            } else {
                context.stroke(path, with: .color(color), lineWidth: a.size)
            }

        case .pen:
            context.stroke(smoothPath(a.points), with: .color(color), style: StrokeStyle(lineWidth: a.size, lineCap: .round, lineJoin: .round))

        case .marker:
            var marker = base
            marker.blendMode = a.color.isLight ? .multiply : .normal
            marker.opacity = a.color.isLight ? 0.55 : 0.4
            marker.stroke(smoothPath(a.points), with: .color(color), style: StrokeStyle(lineWidth: a.size * 4, lineCap: .round, lineJoin: .round))

        case .counter:
            let r = a.counterRadius
            let circle = Path(ellipseIn: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(color))
            let plain = base
            plain.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: max(r * 0.1, 1.5))
            let ink: Color = a.color.isLight ? Color(white: 0.1) : .white
            let label = plain.resolve(Text("\(a.number)").font(.custom(Jakarta.Weight.extrabold.postScriptName, fixedSize: r * 1.1)).foregroundColor(ink))
            plain.draw(label, at: a.start, anchor: .center)

        case .text:
            drawText(a, in: base, pointScale: pointScale)

        case .redact, .spotlight:
            break
        }
    }

    private static func drawText(_ a: Annotation, in base: GraphicsContext, pointScale: CGFloat) {
        guard !a.text.isEmpty else { return }
        var context = base
        let frame = a.textFrame
        let pad = a.textPadding
        let ink: Color
        if a.textStyle == .filled {
            var bubble = base
            bubble.addFilter(.shadow(color: .black.opacity(0.22), radius: 3 * pointScale, x: 0, y: pointScale))
            bubble.fill(Path(roundedRect: frame, cornerRadius: a.fontSize * 0.3, style: .continuous), with: .color(a.color.color))
            ink = a.color.isLight ? Color(white: 0.1) : .white
        } else {
            context.addFilter(.shadow(color: .black.opacity(a.color.isLight ? 0.55 : 0.25), radius: 2 * pointScale, x: 0, y: 0.5 * pointScale))
            ink = a.color.color
        }
        let text = context.resolve(
            Text(a.text)
                .font(.custom(Jakarta.Weight.bold.postScriptName, fixedSize: a.fontSize))
                .foregroundColor(ink)
        )
        let inner = CGRect(x: frame.minX + pad.width, y: frame.minY + pad.height, width: frame.width - pad.width * 2 + 4, height: frame.height - pad.height * 2 + 4)
        context.draw(text, in: inner)
    }

    // MARK: Paths

    /// Tapered shaft with a solid head, CleanShot-style.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux

        let headLength = min(max(width * 3.6, 10), length * 0.65)
        let headHalf = headLength * 0.56
        let base = CGPoint(x: end.x - ux * headLength * 0.82, y: end.y - uy * headLength * 0.82)
        let tailHalf = width * 0.22
        let neckHalf = width * 0.62

        func p(_ origin: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + ux * along + nx * across, y: origin.y + uy * along + ny * across)
        }

        var path = Path()
        path.move(to: p(start, 0, tailHalf))
        path.addLine(to: p(base, 0, neckHalf))
        path.addLine(to: p(base, -headLength * 0.18, headHalf))
        path.addLine(to: end)
        path.addLine(to: p(base, -headLength * 0.18, -headHalf))
        path.addLine(to: p(base, 0, -neckHalf))
        path.addLine(to: p(start, 0, -tailHalf))
        path.addArc(center: start, radius: tailHalf, startAngle: .radians(atan2(-ny, -nx)), endAngle: .radians(atan2(ny, nx)), clockwise: false)
        path.closeSubpath()
        return path
    }

    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.last ?? first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            return path
        }
        for i in 1 ..< points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
