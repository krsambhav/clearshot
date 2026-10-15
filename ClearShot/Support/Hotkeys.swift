import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case captureArea, captureWindow, captureFullscreen, captureText, openHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Capture area"
        case .captureWindow: "Capture window"
        case .captureFullscreen: "Capture fullscreen"
        case .captureText: "Capture text"
        case .openHistory: "Open history"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .captureFullscreen: "display"
        case .captureText: "text.viewfinder"
        case .openHistory: "clock.arrow.circlepath"
        }
    }

    static let defaults: [HotkeyAction: Shortcut] = [
        .captureText: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: [.command, .shift]),
        .captureFullscreen: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: [.command, .shift]),
        .captureArea: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift]),
        .captureWindow: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: [.command, .shift]),
        .openHistory: Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: [.command, .shift]),
    ]
}

struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifierFlags: UInt

    static let none = Shortcut(keyCode: .max, modifierFlags: 0)

    init(keyCode: UInt32, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifierFlags: modifiers.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    var isEmpty: Bool { keyCode == .max }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Individual glyphs in macOS order, e.g. ["⌃", "⌥", "⇧", "⌘", "4"].
    var glyphs: [String] {
        guard !isEmpty else { return [] }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(KeyNames.name(for: keyCode))
        return parts
    }

    var displayString: String { glyphs.joined() }

    /// NSMenuItem key equivalent (lowercase character) and modifier mask.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard !isEmpty else { return nil }
        let name = KeyNames.name(for: keyCode).lowercased()
        guard name.count == 1 else { return nil }
        return (name, modifiers)
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func name(for keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        return translate(keyCode)?.uppercased() ?? "?"
    }

    /// Resolves the key's character in the user's current keyboard layout.
    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

// MARK: - Global hotkeys (Carbon; no Accessibility permission required)

private nonisolated func hotkeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotkeyCenter.shared.fire(id: id)
    }
    return noErr
}

@MainActor
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// Actions whose shortcut is taken by another app.
    private(set) var conflicts: Set<HotkeyAction> = []

    @ObservationIgnored var onTrigger: (HotkeyAction) -> Void = { _ in }
    @ObservationIgnored private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var suspended = false

    private let signature: OSType = 0x434C_5348 // "CLSH"

    func install() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, &handlerRef)
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        guard !suspended else { return }
        var failed: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let shortcut = Preferences.shared.shortcuts[action], !shortcut.isEmpty else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index))
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
            }
        }
        conflicts = failed
    }

    /// Temporarily releases every hotkey, e.g. while the user records a new shortcut.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    fileprivate func fire(id: UInt32) {
        let actions = HotkeyAction.allCases
        guard Int(id) < actions.count else { return }
        onTrigger(actions[Int(id)])
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
