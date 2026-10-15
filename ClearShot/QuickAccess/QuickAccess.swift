import AppKit
import SwiftUI

struct QuickAccessItem: Identifiable, Equatable {
    let id: UUID
    var record: CaptureRecord
    let thumbnail: NSImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.record == rhs.record }
}

/// Floating stack of recent capture thumbnails in a screen corner.
@MainActor
@Observable
final class QuickAccessController {
    static let shared = QuickAccessController()

    private(set) var items: [QuickAccessItem] = []
    var hoveredID: UUID?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var closeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var screen: NSScreen?

    static let cardWidth: CGFloat = 232
    private let maxItems = 4

    func show(record: CaptureRecord, image: CGImage) {
        let thumb = ImageCodec.thumbnail(image, maxPixelSize: 720) ?? image
        let item = QuickAccessItem(id: record.id, record: record, thumbnail: NSImage(cgImage: thumb, scale: 2))
        screen = NSScreen.withMouse
        ensurePanel()
        layoutPanel()
        panel?.orderFrontRegardless()
        withAnimation(Motion.snappy) {
            items.append(item)
            if items.count > maxItems { items.removeFirst(items.count - maxItems) }
        }
        scheduleClose(item.id)
    }

    func dismiss(_ id: UUID) {
        closeTasks[id]?.cancel()
        closeTasks[id] = nil
        withAnimation(Motion.snappy) { items.removeAll { $0.id == id } }
        if items.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                if self?.items.isEmpty == true { self?.panel?.orderOut(nil) }
            }
        }
    }

    func dismissAll() {
        for item in items { dismiss(item.id) }
    }

    func setHovered(_ id: UUID?, hovering: Bool) {
        if hovering {
            hoveredID = id
            if let id { closeTasks[id]?.cancel() }
        } else if hoveredID == id {
            hoveredID = nil
            if let id { scheduleClose(id) }
        }
    }

    private func scheduleClose(_ id: UUID) {
        closeTasks[id]?.cancel()
        let seconds = Preferences.shared.quickAccessAutoClose
        guard seconds > 0 else { return }
        closeTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    func refresh(_ record: CaptureRecord, thumbnail: NSImage?) {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return }
        items[index] = QuickAccessItem(id: record.id, record: record, thumbnail: thumbnail ?? items[index].thumbnail)
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = QuickAccessPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: QuickAccessStack(controller: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
    }

    /// The panel spans a fixed column; transparent regions let clicks through to apps below.
    private func layoutPanel() {
        guard let panel, let screen else { return }
        let visible = screen.visibleFrame
        let width = Self.cardWidth + Space.xl * 2
        let height = min(visible.height, 760)
        let x = Preferences.shared.quickAccessCorner == .bottomLeft ? visible.minX : visible.maxX - width
        panel.setFrame(NSRect(x: x, y: visible.minY, width: width, height: height), display: true)
    }
}

final class QuickAccessPanel: NSPanel, TransientPanel {
    override var canBecomeKey: Bool { false }
}

// MARK: - Views

private struct QuickAccessStack: View {
    let controller: QuickAccessController

    var body: some View {
        let leading = Preferences.shared.quickAccessCorner == .bottomLeft
        VStack(spacing: Space.md) {
            Spacer(minLength: 0)
            ForEach(controller.items) { item in
                QuickAccessCard(item: item, controller: controller)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: leading ? .leading : .trailing).combined(with: .opacity),
                            removal: .move(edge: leading ? .leading : .trailing).combined(with: .opacity)
                        )
                    )
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct QuickAccessCard: View {
    let item: QuickAccessItem
    let controller: QuickAccessController

    @State private var hovering = false
    private let app = AppController.shared

    private var imageHeight: CGFloat {
        let aspect = item.thumbnail.size.height / max(item.thumbnail.size.width, 1)
        return min(max(QuickAccessController.cardWidth * aspect, 96), 200)
    }

    var body: some View {
        ZStack {
            Theme.muted
            Image(nsImage: item.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)

            if hovering {
                Rectangle().fill(.black.opacity(0.42)).transition(.opacity)
                actions.transition(.opacity)
            }
        }
        .frame(width: QuickAccessController.cardWidth, height: imageHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadowLg()
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .onHover { inside in
            withAnimation(Motion.quick) { hovering = inside }
            controller.setHovered(item.id, hovering: inside)
        }
        .onTapGesture { open() }
        .onDrag {
            let url = HistoryStore.shared.imageURL(for: item.record)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } preview: {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 160)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .contextMenu {
            Button("Copy") { Task { await app.copy(item.record) } }
            Button("Save") { save() }
            Button("Annotate") { open() }
            Button("Pin to Screen") { pin() }
            Divider()
            Button("Close") { controller.dismiss(item.id) }
        }
    }

    private var actions: some View {
        ZStack {
            VStack(spacing: Space.sm) {
                Button("Copy") {
                    Task {
                        await app.copy(item.record)
                        controller.dismiss(item.id)
                    }
                }
                .buttonStyle(.shad(.secondary, size: .sm))
                .frame(width: 92)
                Button("Save") { save() }
                    .buttonStyle(.shad(.secondary, size: .sm))
                    .frame(width: 92)
            }
            .environment(\.colorScheme, .light)

            VStack {
                HStack {
                    OverlayIcon(symbol: "xmark", help: "Close") { controller.dismiss(item.id) }
                    Spacer()
                    OverlayIcon(symbol: "pencil.tip", help: "Annotate") { open() }
                }
                Spacer()
                HStack {
                    OverlayIcon(symbol: "pin", help: "Pin to screen") { pin() }
                    Spacer()
                    OverlayIcon(symbol: "folder", help: "Show in Finder") { app.revealInFinder(item.record) }
                }
            }
            .padding(Space.sm)
        }
    }

    private func open() {
        app.annotate(item.record)
        controller.dismiss(item.id)
    }

    private func pin() {
        app.pin(item.record)
        controller.dismiss(item.id)
    }

    private func save() {
        Task {
            let record = HistoryStore.shared.record(item.id) ?? item.record
            await app.export(record)
            controller.dismiss(item.id)
        }
    }
}

private struct OverlayIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(hovering ? 0.6 : 0.4)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
