import AppKit
import SwiftUI

/// Creates ClearShot's standard windows and keeps the Dock icon in sync with them:
/// the app is a menu-bar accessory until a real window is open.
@MainActor
enum WindowFactory {
    private static var openWindows = Set<ObjectIdentifier>()
    private static var observedWindows = Set<ObjectIdentifier>()

    static func make<Content: View>(
        title: String,
        size: CGSize,
        minSize: CGSize? = nil,
        resizable: Bool = true,
        autosaveName: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives a 52pt title band with the traffic lights centred in it;
        // every header in ClearShot is laid out against that band.
        window.toolbar = NSToolbar(identifier: "ClearShot.\(title)")
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.backgroundColor = Theme.nsBackground
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.tabbingMode = .disallowed
        if let minSize { window.contentMinSize = minSize }
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        window.contentView = host
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        return window
    }

    static func present(_ window: NSWindow) {
        track(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Cooperative activation can be refused when another app is frontmost (e.g. right after
        // launch); make sure the window is still visible on top.
        window.orderFrontRegardless()
        // Don't let the first text field steal focus (and show its ring) on open.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    private static func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        openWindows.insert(id)
        guard !observedWindows.contains(id) else { return }
        observedWindows.insert(id)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                openWindows.remove(id)
                if openWindows.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

enum WindowMetrics {
    /// Height of the unified title band; traffic lights are vertically centred in it.
    static let titleBand: CGFloat = 52
    /// Horizontal room the traffic lights need at the leading edge.
    static let trafficLightsWidth: CGFloat = 78
}

/// Clears the title band in full-size-content windows.
struct TitlebarSpacer: View {
    var body: some View { Color.clear.frame(height: WindowMetrics.titleBand) }
}
