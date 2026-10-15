import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click to record a global shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let action: HotkeyAction

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false
    @State private var message: String?
    private let prefs = Preferences.shared

    private var shortcut: Shortcut { prefs.shortcuts[action] ?? .none }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    if recording {
                        Text("Type shortcut…")
                            .font(.jakarta(12, .medium))
                            .foregroundStyle(Theme.brand)
                    } else if shortcut.isEmpty {
                        Text("Record shortcut")
                            .font(.jakarta(12, .medium))
                            .foregroundStyle(Theme.mutedForeground)
                    } else {
                        ForEach(Array(shortcut.glyphs.enumerated()), id: \.offset) { _, glyph in
                            Kbd(keys: glyph)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 132, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(hovering && !recording ? Theme.accent : Theme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(recording ? Theme.brand : Theme.input, lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: Radius.md + 3, style: .continuous)
                        .stroke(Theme.ring, lineWidth: 3)
                        .padding(-1.5)
                        .opacity(recording ? 1 : 0)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: recording)
            .accessibilityLabel("\(action.title) shortcut: \(shortcut.isEmpty ? "none" : shortcut.displayString)")

            if let message {
                Text(message)
                    .textStyle(.caption)
                    .foregroundStyle(Theme.destructive)
            } else if HotkeyCenter.shared.conflicts.contains(action) {
                Text("In use by another app")
                    .textStyle(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        message = nil
        recording = true
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyCenter.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if keyCode == kVK_Escape && modifiers.isEmpty { stop(); return }
        if (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) && modifiers.isEmpty {
            prefs.shortcuts[action] = Shortcut.none
            stop()
            return
        }
        let isFunctionKey = KeyNames.functionKeys.contains(keyCode)
        guard isFunctionKey || !modifiers.subtracting(.shift).isEmpty else {
            message = "Add ⌘, ⌥ or ⌃"
            return
        }
        let candidate = Shortcut(keyCode: UInt32(keyCode), modifiers: modifiers)
        if let clash = prefs.shortcuts.first(where: { $0.key != action && $0.value == candidate }) {
            message = "Already used for \(clash.key.title.lowercased())"
            return
        }
        message = nil
        prefs.shortcuts[action] = candidate
        stop()
    }
}
