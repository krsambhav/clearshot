import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Jakarta.register()
        #if DEBUG
        if DebugSnapshots.runIfRequested() { return }
        #endif
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build()

        StatusBarController.install()
        HotkeyCenter.shared.onTrigger = { action in AppController.shared.perform(action) }
        HotkeyCenter.shared.install()
        HistoryStore.shared.prune()

        if !Preferences.shared.hasCompletedOnboarding || !ScreenPermission.isGranted {
            OnboardingWindowController.shared.show(startAtPermission: Preferences.shared.hasCompletedOnboarding)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.saveNow()
    }

    /// clearshot://capture-area | capture-window | capture-fullscreen | capture-text | history | settings
    /// and image files dropped on the app, which open in the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                AppController.shared.openImageFile(url)
                continue
            }
            guard url.scheme == "clearshot" else { continue }
            switch url.host() ?? url.path() {
            case "capture-area": AppController.shared.capture(.area)
            case "capture-window": AppController.shared.capture(.window)
            case "capture-fullscreen": AppController.shared.capture(.fullscreen)
            case "capture-text": AppController.shared.capture(.text)
            case "history": HistoryWindowController.shared.show()
            case "settings": SettingsWindowController.shared.show()
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }
}

/// Standard menus so text editing and window shortcuts work whenever a ClearShot window is key.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(ClosureMenuItem(title: "About ClearShot") { SettingsWindowController.shared.show(.about) })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { SettingsWindowController.shared.show() })
        appMenu.addItem(ClosureMenuItem(title: "History", keyEquivalent: "y") { HistoryWindowController.shared.show() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ClearShot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ClearShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let captureItem = NSMenuItem()
        let captureMenu = NSMenu(title: "Capture")
        for action in [HotkeyAction.captureArea, .captureWindow, .captureFullscreen, .captureText] {
            captureMenu.addItem(ClosureMenuItem(title: action.title) { AppController.shared.perform(action) })
        }
        captureItem.submenu = captureMenu
        main.addItem(captureItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
