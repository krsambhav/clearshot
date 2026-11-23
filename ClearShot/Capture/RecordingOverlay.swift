import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class RecordingOverlay {
    private var panels: [OverlayPanel] = []
    private var previousApp: NSRunningApplication?
    private var completion: ((NSScreen, CGRect?) -> Void)?

    func present(_ completion: @escaping (NSScreen, CGRect?) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        let activeScreen = NSScreen.withMouse
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let view = RecordingSelectionView(size: screen.frame.size) { [weak self] region in
                self?.select(screen, region: region)
            } cancel: { [weak self] in
                self?.dismiss()
            }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            if screen == activeScreen {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
    }

    func dismiss() {
        completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        if let previousApp, previousApp != NSRunningApplication.current, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        previousApp = nil
        NSCursor.arrow.set()
    }

    var isVisible: Bool { !panels.isEmpty }

    private func select(_ screen: NSScreen, region: CGRect?) {
        guard let completion else { return }
        dismiss()
        completion(screen, region)
    }
}

private final class RecordingSelectionView: NSView {
    private let select: (CGRect?) -> Void
    private let cancel: () -> Void
    private let shade = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var origin: CGPoint?

    init(size: CGSize, select: @escaping (CGRect?) -> Void, cancel: @escaping () -> Void) {
        self.select = select
        self.cancel = cancel
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        shade.fillColor = NSColor(white: 0.28, alpha: 0.28).cgColor
        shade.fillRule = .evenOdd
        outline.fillColor = nil
        outline.strokeColor = Theme.overlayInk.cgColor
        outline.lineWidth = 1.5
        layer?.isGeometryFlipped = true
        layer?.addSublayer(shade)
        layer?.addSublayer(outline)

        let toolbar = RecordingHostingView(rootView: HStack(spacing: Space.md) {
            Text("Drag to record an area")
                .textStyle(.body)
            Button("Record Full Screen", systemImage: "display") { select(nil) }
                .buttonStyle(.shad(.primary, size: .sm))
            Button("Cancel", action: cancel)
                .buttonStyle(.shad(.ghost, size: .sm))
        }
        .padding(Space.sm)
        .recordingPanelChrome())
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 48,
                               width: size.width, height: size.height)
        addSubview(toolbar)
        updateSelection(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let toolbar = subviews.first { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(selection(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let region = selection(at: convert(event.locationInWindow, from: nil))
        origin = nil
        updateSelection(nil)
        if let region, region.width >= 8, region.height >= 8 { select(region) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: select(nil)
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }

    private func selection(at point: CGPoint) -> CGRect? {
        guard let origin else { return nil }
        let rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        return rect.intersection(bounds).integral
    }

    private func updateSelection(_ selection: CGRect?) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection { path.addRect(selection) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.path = path
        outline.path = selection.map { CGPath(rect: $0, transform: nil) }
        CATransaction.commit()
    }
}

final class RecordingControlsPanel: NSPanel, TransientPanel {
    init(screen: NSScreen, recorder: ScreenRecorder) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = RecordingHostingView(rootView: RecordingControls(recorder: recorder))
        contentView = host
        let size = host.fittingSize
        let visible = screen.visibleFrame
        setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16,
                        width: size.width, height: size.height), display: true)
    }

    override var canBecomeKey: Bool { true }
}

private final class RecordingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordingDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private struct RecordingControls: View {
    let recorder: ScreenRecorder

    var body: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                VStack(spacing: 2) {
                    ForEach(0..<3) { _ in
                        HStack(spacing: 2) {
                            Circle().frame(width: 2, height: 2)
                            Circle().frame(width: 2, height: 2)
                        }
                    }
                }
                .foregroundStyle(Theme.mutedForeground)
                .accessibilityHidden(true)
                HStack(spacing: Space.xs) {
                    Circle()
                        .fill(recorder.isPaused ? Theme.mutedForeground : Theme.destructive)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(recorder.controlTitle).textStyle(.bodyStrong)
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(width: 118, alignment: .leading)
            .frame(minHeight: 28)
            .overlay {
                RecordingDragArea()
                    .accessibilityHidden(true)
            }
            Button(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
                recorder.togglePause()
            }
            .buttonStyle(.shad(.outline, size: .sm))
            .frame(width: 90)
            .disabled(!recorder.canControl)
            Button("Stop", systemImage: "stop.fill") { recorder.stop() }
                .buttonStyle(.shad(.primary, size: .sm))
                .disabled(!recorder.canControl)
            Button("Delete", systemImage: "trash") { recorder.discard() }
                .buttonStyle(.shad(.ghost, size: .sm))
                .disabled(!recorder.canControl)
        }
        .fixedSize()
        .padding(Space.sm)
        .recordingPanelChrome()
    }
}

private extension View {
    func recordingPanelChrome() -> some View {
        foregroundStyle(Theme.foreground)
            .background(Theme.popover, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Theme.border).allowsHitTesting(false))
    }
}
