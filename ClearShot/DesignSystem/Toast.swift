import AppKit
import SwiftUI

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, warning, error }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
}

/// Sonner-style toasts, presented in a click-through panel at the bottom of the active screen.
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var toasts: [Toast] = []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTasks: [UUID: Task<Void, Never>] = [:]

    private let panelSize = NSSize(width: 440, height: 260)

    func show(_ kind: Toast.Kind, _ title: String, detail: String? = nil, duration: Duration = .seconds(2.6)) {
        let toast = Toast(kind: kind, title: title, detail: detail)
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()

        withAnimation(Motion.snappy) {
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        }

        hideTasks[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        hideTasks[id]?.cancel()
        hideTasks[id] = nil
        withAnimation(Motion.snappy) { toasts.removeAll { $0.id == id } }
        if toasts.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if self?.toasts.isEmpty == true { self?.panel?.orderOut(nil) }
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = ToastPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastStack(center: self))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.withMouse else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panelSize.width / 2, y: frame.minY + Space.xl))
    }
}

private struct ToastStack: View {
    let center: ToastCenter

    var body: some View {
        VStack(spacing: Space.sm) {
            Spacer(minLength: 0)
            ForEach(center.toasts) { toast in
                ToastView(toast: toast)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
            }
        }
        .padding(Space.lg)
        .frame(width: 440, height: 260, alignment: .bottom)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: toast.detail == nil ? .center : .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .textStyle(.bodyStrong)
                    .foregroundStyle(Theme.foreground)
                if let detail = toast.detail {
                    Text(detail)
                        .textStyle(.footnote)
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 14)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadowLg()
    }

    private var symbol: String {
        switch toast.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: Theme.success
        case .info: Theme.foreground
        case .warning: Theme.warning
        case .error: Theme.destructive
        }
    }
}

extension NSScreen {
    static var withMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

final class ToastPanel: NSPanel, TransientPanel {}
