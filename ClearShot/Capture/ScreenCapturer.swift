import AppKit
@preconcurrency import ScreenCaptureKit

/// A frozen image of one display, taken the instant a capture starts.
struct DisplaySnapshot {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat

    /// Screen frame in global Cocoa coordinates.
    var frame: CGRect { screen.frame }
}

/// An on-screen window that can be picked in window mode.
struct WindowTarget {
    let window: SCWindow
    /// Frame in global Cocoa coordinates (origin bottom-left of the primary display).
    let frame: CGRect
    let title: String
    let appName: String
}

/// Marker for ClearShot panels that must never appear in a capture.
protocol TransientPanel: NSWindow {}

struct CaptureSession {
    let displays: [DisplaySnapshot]
    /// Front-to-back.
    let windows: [WindowTarget]
}

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to capture."
        case .permissionDenied: "ClearShot needs Screen Recording permission."
        }
    }
}

@MainActor
final class ScreenCapturer {
    /// Freezes every display and gathers the window list in one pass.
    func snapshot() async throws -> CaptureSession {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenPermission.isGranted ? error : CaptureError.permissionDenied
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        // Hide ClearShot's transient chrome (Quick Access, toasts, menu) but keep its real
        // windows capturable, e.g. for screenshots of Settings.
        let ownWindowNumbers = Set(NSApp.windows.filter { $0 is TransientPanel && $0.isVisible }.map { CGWindowID($0.windowNumber) })
        let hidden = content.windows.filter { ownWindowNumbers.contains($0.windowID) }

        var displays: [DisplaySnapshot] = []
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, screen) in NSScreen.screens.enumerated() {
                guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: hidden)
                let config = Self.configuration(size: screen.frame.size, scale: screen.backingScaleFactor)
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (index, image)
                }
            }
            var images: [Int: CGImage] = [:]
            for try await (index, image) in group { images[index] = image }
            for (index, screen) in NSScreen.screens.enumerated() {
                if let image = images[index] {
                    displays.append(DisplaySnapshot(screen: screen, image: image, scale: screen.backingScaleFactor))
                }
            }
        }
        guard !displays.isEmpty else { throw CaptureError.noDisplay }

        return CaptureSession(displays: displays, windows: Self.windowTargets(from: content, ownBundleID: ownBundleID))
    }

    /// Captures a single window on its own, so overlapping windows don't bleed in.
    /// With `onWallpaper`, the window is set on the desktop wallpaper with a shadow.
    func capture(window target: WindowTarget, onWallpaper: Bool) async throws -> (CGImage, CGFloat) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) }
            ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let config = Self.configuration(size: target.frame.size, scale: scale)
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        guard onWallpaper, let screen else { return (image, scale) }
        let wallpaper = await (try? captureWallpaper(of: screen)) ?? WindowBackdrop.fallbackWallpaper(for: screen)
        guard let wallpaper, let composed = WindowBackdrop.compose(window: image, wallpaper: wallpaper, scale: scale) else {
            return (image, scale)
        }
        return (composed, scale)
    }

    /// Captures the live wallpaper window, so dynamic and aerial wallpapers look as they do on screen.
    private func captureWallpaper(of screen: NSScreen) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        // Everything below the desktop icons: the wallpaper and the backstop under it.
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let layers = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(display.frame) }
        guard !layers.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: layers)
        let config = Self.configuration(size: screen.frame.size, scale: screen.backingScaleFactor)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func configuration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private static func windowTargets(from content: SCShareableContent, ownBundleID: String?) -> [WindowTarget] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let excludedOwners: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui"]

        // CGWindowList is ordered front-to-back; ScreenCaptureKit's list is not.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        return content.windows
            .filter { window in
                guard window.isOnScreen, window.windowLayer == 0,
                      window.frame.width > 40, window.frame.height > 40,
                      let app = window.owningApplication else { return false }
                return app.bundleIdentifier != ownBundleID && !excludedOwners.contains(app.bundleIdentifier)
            }
            .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
            .map { window in
                let cg = window.frame
                let frame = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
                return WindowTarget(
                    window: window,
                    frame: frame,
                    title: window.title ?? "",
                    appName: window.owningApplication?.applicationName ?? ""
                )
            }
    }
}
