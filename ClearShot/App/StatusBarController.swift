import AppKit
import SwiftUI

/// Menu bar item with a shadcn-style dropdown panel.
@MainActor
final class StatusBarController {
    private(set) static var shared: StatusBarController?

    private let item: NSStatusItem
    private var panel: MenuPanel?
    private var outsideClickMonitor: Any?

    static func install() {
        shared = StatusBarController()
    }

    private init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.icon()
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("ClearShot")
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true { closeMenu() } else { openMenu() }
    }

    func openMenu() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? CGSize(width: 300, height: 400)
        var origin = CGPoint(x: buttonFrame.minX - 8, y: buttonFrame.minY - size.height - 6)
        if let screen = buttonWindow.screen {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        button.highlight(true)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { StatusBarController.shared?.closeMenu() }
        }
    }

    func closeMenu() {
        item.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel()
        let host = NSHostingView(rootView: StatusMenu(close: { [weak self] in self?.closeMenu() }))
        panel.contentView = host
        panel.onResign = { [weak self] in self?.closeMenu() }
        return panel
    }

    /// Viewfinder glyph drawn as a template image so it follows the menu bar's tint.
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let inset = rect.insetBy(dx: 2.25, dy: 2.25)
            let arm: CGFloat = 4.5
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let corners: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: inset.minX, y: inset.maxY), 1, -1),
                (CGPoint(x: inset.maxX, y: inset.maxY), -1, -1),
                (CGPoint(x: inset.minX, y: inset.minY), 1, 1),
                (CGPoint(x: inset.maxX, y: inset.minY), -1, 1),
            ]
            for (corner, dx, dy) in corners {
                path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                path.line(to: corner)
                path.line(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            }
            NSColor.black.setStroke()
            path.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class MenuPanel: NSPanel, TransientPanel {
    var onResign: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    override func cancelOperation(_ sender: Any?) { onResign?() }
}

// MARK: - Menu content

private struct MenuEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: Shortcut?
    let action: () -> Void
}

private struct StatusMenu: View {
    let close: () -> Void

    @State private var highlighted: String?
    @FocusState private var focused: Bool
    private let prefs = Preferences.shared
    private let history = HistoryStore.shared

    private var captureEntries: [MenuEntry] {
        [HotkeyAction.captureArea, .captureWindow, .captureFullscreen, .captureText].map { action in
            MenuEntry(id: action.rawValue, title: action.title, symbol: action.symbol, shortcut: prefs.shortcuts[action]) {
                close()
                // Let the menu fade before the screen freezes.
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    AppController.shared.perform(action)
                }
            }
        }
    }

    private var appEntries: [MenuEntry] {
        [
            MenuEntry(id: "history", title: "History", symbol: "clock.arrow.circlepath", shortcut: prefs.shortcuts[.openHistory]) {
                close(); HistoryWindowController.shared.show()
            },
            MenuEntry(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: Shortcut(keyCode: 43, modifiers: .command)) {
                close(); SettingsWindowController.shared.show()
            },
            MenuEntry(id: "quit", title: "Quit ClearShot", symbol: "power", shortcut: Shortcut(keyCode: 12, modifiers: .command)) {
                NSApp.terminate(nil)
            },
        ]
    }

    private var allEntries: [MenuEntry] { captureEntries + appEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(captureEntries)
            recents
            ShadSeparator().padding(.vertical, Space.xs).padding(.horizontal, -Space.xs)
            section(appEntries)
        }
        .padding(Space.xs)
        .frame(width: 276)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .padding(Space.lg)
        .shadowLg()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            allEntries.first { $0.id == highlighted }?.action()
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func move(_ delta: Int) {
        let ids = allEntries.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        highlighted = ids[(index + delta + ids.count) % ids.count]
    }

    private func section(_ entries: [MenuEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                MenuRow(entry: entry, highlighted: highlighted == entry.id) { inside in
                    if inside { highlighted = entry.id } else if highlighted == entry.id { highlighted = nil }
                }
            }
        }
    }

    @ViewBuilder
    private var recents: some View {
        let recent = Array(history.records.filter { $0.kind == .screenshot }.prefix(3))
        if !recent.isEmpty {
            ShadSeparator().padding(.vertical, Space.xs).padding(.horizontal, -Space.xs)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Recent")
                    .textStyle(.caption)
                    .foregroundStyle(Theme.mutedForeground)
                HStack(spacing: Space.sm) {
                    ForEach(recent) { record in
                        RecentThumb(record: record) {
                            close()
                            AppController.shared.annotate(record)
                        }
                    }
                    ForEach(0 ..< max(0, 3 - recent.count), id: \.self) { _ in
                        Color.clear.frame(height: 52)
                    }
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
        }
    }
}

private struct MenuRow: View {
    let entry: MenuEntry
    let highlighted: Bool
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: entry.action) {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16)
                    .foregroundStyle(Theme.mutedForeground)
                Text(entry.title)
                    .textStyle(.body)
                    .foregroundStyle(Theme.foreground)
                Spacer(minLength: Space.md)
                if let shortcut = entry.shortcut, !shortcut.isEmpty {
                    Text(shortcut.displayString)
                        .font(.jakarta(12, .medium))
                        .tracking(1.5)
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(highlighted ? Theme.accent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }
}

private struct RecentThumb: View {
    let record: CaptureRecord
    let action: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Theme.muted
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(hovering ? Theme.brand : Theme.border, lineWidth: hovering ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in editor")
        .task(id: record.id) { image = await HistoryStore.shared.thumbnail(for: record) }
    }
}
