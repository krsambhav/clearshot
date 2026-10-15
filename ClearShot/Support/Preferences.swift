import AppKit
import Foundation

enum ImageFormat: String, CaseIterable, Codable {
    case png, jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
    var label: String { self == .png ? "PNG" : "JPEG" }
}

enum QuickAccessCorner: String, CaseIterable, Codable {
    case bottomLeft, bottomRight

    var label: String { self == .bottomLeft ? "Bottom left" : "Bottom right" }
}

/// User preferences, persisted to UserDefaults and observable from SwiftUI.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    // After capture
    var copyToClipboard: Bool { didSet { save(copyToClipboard, "copyToClipboard") } }
    var saveToFolder: Bool { didSet { save(saveToFolder, "saveToFolder") } }
    var exportFolderPath: String { didSet { save(exportFolderPath, "exportFolderPath") } }
    var imageFormat: ImageFormat { didSet { save(imageFormat.rawValue, "imageFormat") } }
    var downscaleRetina: Bool { didSet { save(downscaleRetina, "downscaleRetina") } }
    var playSounds: Bool { didSet { save(playSounds, "playSounds") } }

    // Quick Access
    var showQuickAccess: Bool { didSet { save(showQuickAccess, "showQuickAccess") } }
    var quickAccessCorner: QuickAccessCorner { didSet { save(quickAccessCorner.rawValue, "quickAccessCorner") } }
    /// Seconds before an untouched thumbnail closes. 0 keeps it open.
    var quickAccessAutoClose: Int { didSet { save(quickAccessAutoClose, "quickAccessAutoClose") } }

    // Capture overlay
    var showCrosshair: Bool { didSet { save(showCrosshair, "showCrosshair") } }

    // Text recognition
    var ocrKeepLineBreaks: Bool { didSet { save(ocrKeepLineBreaks, "ocrKeepLineBreaks") } }
    var ocrDetectCodes: Bool { didSet { save(ocrDetectCodes, "ocrDetectCodes") } }
    var ocrLanguageCorrection: Bool { didSet { save(ocrLanguageCorrection, "ocrLanguageCorrection") } }

    // History
    /// Days to keep captures. 0 keeps everything.
    var historyRetentionDays: Int { didSet { save(historyRetentionDays, "historyRetentionDays") } }

    var shortcuts: [HotkeyAction: Shortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) { defaults.set(data, forKey: "shortcuts") }
        }
    }

    var exportFolder: URL {
        URL(fileURLWithPath: (exportFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private init() {
        let d = UserDefaults.standard
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        copyToClipboard = d.object(forKey: "copyToClipboard") as? Bool ?? true
        saveToFolder = d.object(forKey: "saveToFolder") as? Bool ?? true
        exportFolderPath = d.string(forKey: "exportFolderPath") ?? "~/Documents/ClearShot"
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        downscaleRetina = d.bool(forKey: "downscaleRetina")
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        showQuickAccess = d.object(forKey: "showQuickAccess") as? Bool ?? true
        quickAccessCorner = QuickAccessCorner(rawValue: d.string(forKey: "quickAccessCorner") ?? "") ?? .bottomLeft
        quickAccessAutoClose = d.object(forKey: "quickAccessAutoClose") as? Int ?? 15
        showCrosshair = d.object(forKey: "showCrosshair") as? Bool ?? true
        ocrKeepLineBreaks = d.object(forKey: "ocrKeepLineBreaks") as? Bool ?? true
        ocrDetectCodes = d.object(forKey: "ocrDetectCodes") as? Bool ?? true
        ocrLanguageCorrection = d.object(forKey: "ocrLanguageCorrection") as? Bool ?? true
        historyRetentionDays = d.object(forKey: "historyRetentionDays") as? Int ?? 30

        if let data = d.data(forKey: "shortcuts"),
           let stored = try? JSONDecoder().decode([HotkeyAction: Shortcut].self, from: data) {
            shortcuts = HotkeyAction.defaults.merging(stored) { _, new in new }
        } else {
            shortcuts = HotkeyAction.defaults
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
