import AppKit
import CoreGraphics
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Image encoding

enum ImageCodec {
    nonisolated static func encode(_ image: CGImage, as format: ImageFormat, dpiScale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * dpiScale,
            kCGImagePropertyDPIHeight: 72 * dpiScale,
        ]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    nonisolated static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func thumbnail(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let factor = CGFloat(maxPixelSize) / CGFloat(longest)
        return resized(image, to: CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
    }

    nonisolated static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension CGImage {
    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

extension NSImage {
    convenience init(cgImage: CGImage, scale: CGFloat) {
        self.init(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }
}

// MARK: - Clipboard

enum Clipboard {
    @discardableResult
    static func copy(image: CGImage, pngData: Data? = nil, scale: CGFloat = 2) -> Bool {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        if let png = pngData ?? ImageCodec.encode(image, as: .png, dpiScale: scale) {
            item.setData(png, forType: .png)
        }
        if let tiff = NSImage(cgImage: image, scale: scale).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        guard !item.types.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Sounds

enum Sounds {
    private static let base = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static let shutter = NSSound(contentsOfFile: base + "Screen Capture.aif", byReference: true)
    private static let copy = NSSound(named: "Pop")

    static func playShutter() {
        guard Preferences.shared.playSounds else { return }
        shutter?.stop()
        shutter?.play()
    }

    static func playCopied() {
        guard Preferences.shared.playSounds else { return }
        copy?.stop()
        copy?.volume = 0.5
        copy?.play()
    }
}

// MARK: - File naming

enum FileNaming {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    static func baseName(for date: Date) -> String {
        "ClearShot \(formatter.string(from: date))"
    }

    /// Returns a URL in `folder` that doesn't collide with an existing file.
    static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns the login item on once, the first time an installed copy launches.
    /// After that the user's choice in Settings sticks.
    static func enableByDefault() {
        let key = "loginItemDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { set(true) }
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            ToastCenter.shared.show(.error, "Couldn't change login item", detail: error.localizedDescription)
        }
    }
}

// MARK: - Screen recording permission

enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
