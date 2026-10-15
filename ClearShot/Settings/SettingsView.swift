import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, capture, quickAccess, shortcuts, text, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .quickAccess: "Quick Access"
        case .shortcuts: "Shortcuts"
        case .text: "Text Recognition"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .quickAccess: "rectangle.stack"
        case .shortcuts: "command"
        case .text: "text.viewfinder"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }

    var summary: String {
        switch self {
        case .general: "Startup and feedback."
        case .capture: "What happens the moment you take a screenshot."
        case .quickAccess: "The thumbnail that appears after each capture."
        case .shortcuts: "Global shortcuts work from any app."
        case .text: "Copy text from anything on screen, on-device."
        case .history: "Every capture is kept locally so you can come back to it."
        case .about: ""
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let model = SettingsModel()

    func show(_ section: SettingsSection? = nil) {
        if let section { model.section = section }
        if window == nil {
            window = WindowFactory.make(title: "ClearShot Settings", size: CGSize(width: 760, height: 560), minSize: CGSize(width: 700, height: 480), autosaveName: "Settings") {
                SettingsView(model: model)
            }
        }
        if let window { WindowFactory.present(window) }
    }
}

@MainActor
@Observable
final class SettingsModel {
    var section: SettingsSection = .general
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ShadSeparator(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.section != .about {
                        Text(model.section.title)
                            .textStyle(.title2)
                            .foregroundStyle(Theme.foreground)
                        Text(model.section.summary)
                            .textStyle(.body)
                            .foregroundStyle(Theme.mutedForeground)
                            .padding(.top, Space.xs)
                        ShadSeparator().padding(.top, Space.lg).padding(.bottom, Space.xs)
                    }
                    content
                }
                .padding(.horizontal, Space.xxl)
                .padding(.top, WindowMetrics.titleBand + 2)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(model.section)
            }
            .scrollIndicators(.automatic)
            .background(Theme.background)
        }
        .background(Theme.background)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            TitlebarSpacer()
            ForEach(SettingsSection.allCases) { section in
                SidebarButton(title: section.title, symbol: section.symbol, selected: model.section == section) {
                    model.section = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, Space.md)
        .frame(width: 208)
        .background(Theme.muted.opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general: GeneralSettings()
        case .capture: CaptureSettings()
        case .quickAccess: QuickAccessSettings()
        case .shortcuts: ShortcutSettings()
        case .text: TextSettings()
        case .history: HistorySettings()
        case .about: AboutView()
        }
    }
}

struct SidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    var count: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
                Text(title)
                    .font(.jakarta(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.jakarta(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Theme.background : (hovering ? Theme.accent : .clear))
                    .shadow(color: selected ? .black.opacity(0.05) : .clear, radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.border : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Sections

private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.jakarta(11, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.xs)
            }
            content
        }
    }
}

private struct GeneralSettings: View {
    @Bindable private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        SettingsGroup {
            FieldRow(title: "Open at login", description: "Start ClearShot quietly in the menu bar.") {
                Toggle("", isOn: $launchAtLogin).toggleStyle(.shad).labelsHidden()
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.set(value) }
            }
            ShadSeparator()
            FieldRow(title: "Play sounds", description: "A soft shutter on capture, a tick when text is copied.") {
                Toggle("", isOn: $prefs.playSounds).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Screen Recording", description: ScreenPermission.isGranted ? "Granted. ClearShot can see your screen." : "Required to capture anything on screen.") {
                if ScreenPermission.isGranted {
                    ShadBadge(text: "Granted")
                } else {
                    Button("Open Settings") { ScreenPermission.openSystemSettings() }
                        .buttonStyle(.shad(.outline, size: .sm))
                }
            }
        }
    }
}

private struct CaptureSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup(title: "After capture") {
            FieldRow(title: "Copy to clipboard", description: "Paste the screenshot anywhere right away.") {
                Toggle("", isOn: $prefs.copyToClipboard).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Save to folder", description: prefs.exportFolder.abbreviatedPath) {
                HStack(spacing: Space.sm) {
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(.shad(.outline, size: .sm))
                    Toggle("", isOn: $prefs.saveToFolder).toggleStyle(.shad).labelsHidden()
                }
            }
            ShadSeparator()
            FieldRow(title: "File format") {
                ShadTabs(selection: $prefs.imageFormat, options: ImageFormat.allCases.map { ($0, $0.label) })
            }
            ShadSeparator()
            FieldRow(title: "Save Retina captures at 1×", description: "Halves file size; text gets softer.") {
                Toggle("", isOn: $prefs.downscaleRetina).toggleStyle(.shad).labelsHidden()
            }
        }
        SettingsGroup(title: "Selection") {
            FieldRow(title: "Crosshair", description: "Full-screen guides for lining up a selection.") {
                Toggle("", isOn: $prefs.showCrosshair).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Magnifier", description: "A pixel loupe that follows the pointer.") {
                Toggle("", isOn: $prefs.showMagnifier).toggleStyle(.shad).labelsHidden()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = prefs.exportFolder
        if panel.runModal() == .OK, let url = panel.url {
            prefs.exportFolderPath = (url.path as NSString).abbreviatingWithTildeInPath
            prefs.saveToFolder = true
        }
    }
}

private struct QuickAccessSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            FieldRow(title: "Show after capture", description: "Drag it into any app, or hover for copy, save, annotate and pin.") {
                Toggle("", isOn: $prefs.showQuickAccess).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Position") {
                ShadTabs(selection: $prefs.quickAccessCorner, options: QuickAccessCorner.allCases.map { ($0, $0.label) })
            }
            .disabled(!prefs.showQuickAccess)
            ShadSeparator()
            FieldRow(title: "Close automatically", description: "Hovering a thumbnail keeps it open.") {
                ShadSelect(selection: $prefs.quickAccessAutoClose, options: [
                    (0, "Never"), (5, "After 5 seconds"), (10, "After 10 seconds"),
                    (15, "After 15 seconds"), (30, "After 30 seconds"), (60, "After 1 minute"),
                ])
            }
            .disabled(!prefs.showQuickAccess)
        }
    }
}

private struct ShortcutSettings: View {
    private let prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { ShadSeparator() }
                HStack(spacing: Space.md) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(width: 20)
                    Text(action.title)
                        .textStyle(.label)
                        .foregroundStyle(Theme.foreground)
                    Spacer()
                    ShortcutRecorder(action: action)
                }
                .padding(.vertical, Space.md)
            }
        }
        .onChange(of: prefs.shortcuts) { _, _ in HotkeyCenter.shared.registerAll() }

        HStack {
            Text("Tip: in the capture overlay, press Space to switch between area and window.")
                .textStyle(.footnote)
                .foregroundStyle(Theme.mutedForeground)
            Spacer()
            Button("Restore defaults") {
                prefs.shortcuts = HotkeyAction.defaults
            }
            .buttonStyle(.shad(.ghost, size: .sm))
        }
        .padding(.top, Space.lg)
    }
}

private struct TextSettings: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            FieldRow(title: "Keep line breaks", description: "Off joins wrapped lines into flowing paragraphs.") {
                Toggle("", isOn: $prefs.ocrKeepLineBreaks).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Language correction", description: "Fixes likely misreads. Turn off for code and IDs.") {
                Toggle("", isOn: $prefs.ocrLanguageCorrection).toggleStyle(.shad).labelsHidden()
            }
            ShadSeparator()
            FieldRow(title: "Read QR codes and barcodes", description: "Copies the code's contents when there's no text.") {
                Toggle("", isOn: $prefs.ocrDetectCodes).toggleStyle(.shad).labelsHidden()
            }
        }
        HStack(spacing: Space.sm) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.mutedForeground)
            Text("Recognition runs entirely on this Mac with Apple's Vision framework. Nothing leaves your device.")
                .textStyle(.footnote)
                .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.top, Space.lg)
    }
}

private struct HistorySettings: View {
    @Bindable private var prefs = Preferences.shared
    @State private var confirming = false
    private let history = HistoryStore.shared

    var body: some View {
        SettingsGroup {
            FieldRow(title: "Keep captures for") {
                ShadSelect(selection: $prefs.historyRetentionDays, options: [
                    (1, "1 day"), (7, "1 week"), (30, "1 month"), (90, "3 months"), (0, "Forever"),
                ])
            }
            ShadSeparator()
            FieldRow(title: "Clear history", description: "\(history.records.count) captures. Files you saved to a folder are kept.") {
                HStack(spacing: Space.sm) {
                    if confirming {
                        Button("Cancel") { withAnimation(Motion.quick) { confirming = false } }
                            .buttonStyle(.shad(.ghost, size: .sm))
                        Button("Delete all") {
                            history.deleteAll()
                            withAnimation(Motion.quick) { confirming = false }
                        }
                        .buttonStyle(.shad(.destructive, size: .sm))
                    } else {
                        Button("Clear…") { withAnimation(Motion.quick) { confirming = true } }
                            .buttonStyle(.shad(.outline, size: .sm))
                            .disabled(history.records.isEmpty)
                    }
                }
            }
        }
        .onChange(of: prefs.historyRetentionDays) { _, _ in history.prune() }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("ClearShot")
                    .textStyle(.title1)
                    .foregroundStyle(Theme.foreground)
                Text("Version \(version)")
                    .textStyle(.body)
                    .foregroundStyle(Theme.mutedForeground)
            }
            Text("A fast, open-source screenshot and text-capture tool for macOS. Free forever, no account, no cloud.")
                .textStyle(.body)
                .foregroundStyle(Theme.foreground)
                .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: Space.sm) {
                Button {
                    OnboardingWindowController.shared.show(startAtPermission: false)
                } label: {
                    Label("Show welcome", systemImage: "sparkles")
                }
                .buttonStyle(.shad(.ghost, size: .sm))
            }
            ShadSeparator().padding(.vertical, Space.sm)
            Text("Set in Plus Jakarta Sans by Tokotype, licensed under the SIL Open Font License. Interface patterns from shadcn/ui.")
                .textStyle(.footnote)
                .foregroundStyle(Theme.mutedForeground)
                .frame(maxWidth: 420, alignment: .leading)
        }
    }
}
