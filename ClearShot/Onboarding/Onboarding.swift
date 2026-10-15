import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private let model = OnboardingModel()

    func show(startAtPermission: Bool) {
        if startAtPermission { model.step = .permission }
        if window == nil {
            window = WindowFactory.make(title: "Welcome to ClearShot", size: CGSize(width: 600, height: 520), resizable: false) {
                OnboardingView(model: model) { [weak self] in self?.window?.close() }
            }
        }
        if let window { WindowFactory.present(window) }
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, permission, shortcuts }
    var step: Step = .welcome
    var permissionGranted = ScreenPermission.isGranted
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitlebarSpacer()
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permission: PermissionStep(model: model)
                case .shortcuts: ShortcutsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, Space.sm)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(model.step)

            ShadSeparator()
            HStack {
                HStack(spacing: 6) {
                    ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                        Capsule()
                            .fill(step == model.step ? Theme.foreground : Theme.input)
                            .frame(width: step == model.step ? 18 : 6, height: 6)
                    }
                }
                .animation(Motion.snappy, value: model.step)
                Spacer()
                if model.step != .welcome {
                    Button("Back") { go(-1) }
                        .buttonStyle(.shad(.ghost))
                }
                Button(primaryTitle) { advance() }
                    .buttonStyle(.shad(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xl)
            .frame(height: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .ignoresSafeArea()
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: "Get started"
        case .permission: model.permissionGranted ? "Continue" : "Skip for now"
        case .shortcuts: "Done"
        }
    }

    private func advance() {
        if model.step == .shortcuts {
            Preferences.shared.hasCompletedOnboarding = true
            finish()
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingModel.Step(rawValue: model.step.rawValue + delta) else { return }
        withAnimation(Motion.snappy) { model.step = next }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                // The icon artwork has a built-in margin; pull it onto the text edge.
                .padding(.leading, -8)
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Capture anything.\nCopy any text.")
                    .textStyle(.display)
                    .foregroundStyle(Theme.foreground)
                    .lineSpacing(2)
                Text("ClearShot lives in your menu bar. Press a shortcut, drag over the screen, and it's on your clipboard before you let go.")
                    .font(.jakarta(15))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineSpacing(3)
                    .frame(maxWidth: 470, alignment: .leading)
            }
            HStack(spacing: Space.sm) {
                ShadBadge(text: "Open source", variant: .outline)
                ShadBadge(text: "On-device text recognition", variant: .outline)
                ShadBadge(text: "No account", variant: .outline)
            }
        }
    }
}

private struct PermissionStep: View {
    @Bindable var model: OnboardingModel
    @State private var requested = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Allow screen access")
                    .textStyle(.title1)
                    .foregroundStyle(Theme.foreground)
                Text("macOS asks before any app can see your screen. ClearShot only looks when you press a capture shortcut, and nothing leaves your Mac.")
                    .font(.jakarta(15))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineSpacing(3)
                    .frame(maxWidth: 460, alignment: .leading)
            }

            ShadCard {
                HStack(spacing: Space.lg) {
                    ZStack {
                        Circle().fill(model.permissionGranted ? Theme.success.opacity(0.14) : Theme.muted)
                        Image(systemName: model.permissionGranted ? "checkmark" : "rectangle.dashed.badge.record")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(model.permissionGranted ? Theme.success : Theme.foreground)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen & System Audio Recording")
                            .textStyle(.bodyStrong)
                            .foregroundStyle(Theme.foreground)
                        Text(statusText)
                            .textStyle(.footnote)
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    Spacer()
                    if model.permissionGranted {
                        ShadBadge(text: "Allowed")
                    } else if requested {
                        Button("Relaunch") { ScreenPermission.relaunch() }
                            .buttonStyle(.shad(.outline, size: .sm))
                    } else {
                        Button("Allow…") {
                            requested = true
                            if !ScreenPermission.request() { ScreenPermission.openSystemSettings() }
                        }
                        .buttonStyle(.shad(.primary, size: .sm))
                    }
                }
            }

            if requested && !model.permissionGranted {
                Text("Turn on ClearShot in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to relaunch the app afterwards.")
                    .textStyle(.footnote)
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
        .task {
            while !Task.isCancelled && !model.permissionGranted {
                try? await Task.sleep(for: .seconds(1))
                model.permissionGranted = ScreenPermission.isGranted
            }
        }
    }

    private var statusText: String {
        if model.permissionGranted { return "You're all set." }
        return requested ? "Waiting for you to allow access…" : "Required for screenshots and text capture."
    }
}

private struct ShortcutsStep: View {
    private let prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Your shortcuts")
                    .textStyle(.title1)
                    .foregroundStyle(Theme.foreground)
                Text("They work from any app. Change them anytime in Settings.")
                    .font(.jakarta(15))
                    .foregroundStyle(Theme.mutedForeground)
            }
            VStack(spacing: 0) {
                ForEach(Array([HotkeyAction.captureText, .captureArea, .captureWindow, .captureFullscreen].enumerated()), id: \.element) { index, action in
                    if index > 0 { ShadSeparator() }
                    HStack(spacing: Space.md) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(action == .captureText ? Theme.brand : Theme.mutedForeground)
                            .frame(width: 20)
                        Text(action.title)
                            .textStyle(.label)
                            .foregroundStyle(Theme.foreground)
                        if action == .captureText {
                            ShadBadge(text: "Try it", variant: .brand)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array((prefs.shortcuts[action] ?? .none).glyphs.enumerated()), id: \.offset) { _, glyph in
                                Kbd(keys: glyph)
                            }
                        }
                    }
                    .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, Space.lg)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}
