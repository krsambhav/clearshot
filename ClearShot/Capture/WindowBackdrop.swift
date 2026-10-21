import AppKit

/// Places a captured window on the desktop wallpaper with padding and a soft shadow.
enum WindowBackdrop {
    static func compose(window: CGImage, wallpaper: CGImage, scale: CGFloat) -> CGImage? {
        let windowSize = CGSize(width: window.width, height: window.height)
        // Roughly 100pt around a typical window, less for small ones.
        let padding = (min(windowSize.width, windowSize.height) / scale * 0.15).clamped(to: 32...100) * scale
        let canvas = CGSize(width: windowSize.width + padding * 2, height: windowSize.height + padding * 2)

        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width.rounded()),
            height: Int(canvas.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        // Wallpaper, aspect-filled and centred.
        let wallpaperSize = CGSize(width: wallpaper.width, height: wallpaper.height)
        let fill = max(canvas.width / wallpaperSize.width, canvas.height / wallpaperSize.height)
        let drawn = CGSize(width: wallpaperSize.width * fill, height: wallpaperSize.height * fill)
        context.draw(wallpaper, in: CGRect(
            x: (canvas.width - drawn.width) / 2,
            y: (canvas.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))

        // A wide ambient shadow around a tight contact shadow, like a focused macOS window.
        let windowRect = CGRect(origin: CGPoint(x: padding, y: padding), size: windowSize)
        context.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 50 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 4 * scale, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.draw(window, in: windowRect)
        context.endTransparencyLayer()

        return context.makeImage()
    }

    /// The wallpaper file for `screen`, for when the live wallpaper window can't be captured.
    static func fallbackWallpaper(for screen: NSScreen?) -> CGImage? {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
