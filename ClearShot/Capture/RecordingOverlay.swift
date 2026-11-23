import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class RecordingOverlay {
    private var panels: [OverlayPanel] = []
    private var previousApp: NSRunningApplication?
    private var completion: ((NSScreen, RecordingTarget, RecordingAudioOptions) -> Void)?
    private let selection = RecordingSelection()
    private var windowLookup: Task<Void, Never>?
    private var windows: [WindowTarget] = []

    func present(_ completion: @escaping (NSScreen, RecordingTarget, RecordingAudioOptions) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        let activeScreen = NSScreen.withMouse
        selection.options = RecordingAudioOptions()
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let view = RecordingSelectionView(screen: screen, selection: selection, overlay: self)
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
        windowLookup?.cancel()
        windowLookup = nil
        windows = []
        selection.windowMode = false
        selection.windowPrompt = ""
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

    fileprivate func select(_ screen: NSScreen, target: RecordingTarget) {
        guard let completion else { return }
        let audio = selection.options
        dismiss()
        completion(screen, target, audio)
    }

    fileprivate func toggleWindowMode() {
        selection.windowMode.toggle()
        windowLookup?.cancel()
        windows = []
        selection.windowPrompt = "Finding windows…"
        refreshSelection(modeChanged: true)
        guard selection.windowMode else { return }
        windowLookup = Task {
            do {
                let targets = try await ScreenCapturer().recordingWindows()
                guard !Task.isCancelled else { return }
                windows = targets
                selection.windowPrompt = targets.isEmpty ? "No windows available" : "Click a window"
                refreshSelection()
            } catch {
                guard !Task.isCancelled else { return }
                selection.windowMode = false
                refreshSelection(modeChanged: true)
                ToastCenter.shared.show(.error, "Couldn't list windows", detail: error.localizedDescription)
            }
        }
    }

    fileprivate func window(at point: CGPoint) -> WindowTarget? {
        windows.first { $0.frame.contains(point) }
    }

    fileprivate func refreshSelection(modeChanged: Bool = false) {
        for panel in panels {
            guard let view = panel.contentView as? RecordingSelectionView else { continue }
            if modeChanged { panel.invalidateCursorRects(for: view) }
            view.refreshWindowHighlight()
        }
    }
}

@Observable
private final class RecordingSelection {
    var options = RecordingAudioOptions()
    var windowMode = false
    var windowPrompt = ""
}

private final class RecordingSelectionView: NSView {
    private let screen: NSScreen
    private let selection: RecordingSelection
    private unowned let overlay: RecordingOverlay
    private let shade = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var origin: CGPoint?
    private var windowClickStarted = false

    init(screen: NSScreen, selection: RecordingSelection, overlay: RecordingOverlay) {
        self.screen = screen
        self.selection = selection
        self.overlay = overlay
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        shade.fillColor = NSColor(white: 0.28, alpha: 0.28).cgColor
        shade.fillRule = .evenOdd
        outline.fillColor = nil
        outline.strokeColor = Theme.overlayInk.cgColor
        outline.lineWidth = 1.5
        layer?.isGeometryFlipped = true
        layer?.addSublayer(shade)
        layer?.addSublayer(outline)

        let toolbar = RecordingHostingView(rootView: RecordingSelectionToolbar(
            selection: selection,
            toggleWindowMode: { [weak overlay] in overlay?.toggleWindowMode() },
            fullScreen: { [weak overlay] in overlay?.select(screen, target: .display(region: nil)) },
            cancel: { [weak overlay] in overlay?.dismiss() }
        ))
        let size = toolbar.fittingSize
        let bottomInset = screen.visibleFrame.minY - screen.frame.minY + Space.xl
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - bottomInset,
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
        addCursorRect(bounds, cursor: selection.windowMode ? .pointingHand : .crosshair)
        if let toolbar = subviews.first { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if selection.windowMode { overlay.refreshSelection() }
    }

    override func mouseMoved(with event: NSEvent) {
        if let window, !window.isKeyWindow {
            window.makeKey()
            window.makeFirstResponder(self)
        }
        if selection.windowMode { overlay.refreshSelection() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        windowClickStarted = selection.windowMode
        guard !selection.windowMode else { return }
        origin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(selection(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        if selection.windowMode {
            if windowClickStarted, let target = overlay.window(at: NSEvent.mouseLocation) {
                overlay.select(screen, target: .window(target))
            }
            windowClickStarted = false
            return
        }
        let region = selection(at: convert(event.locationInWindow, from: nil))
        origin = nil
        updateSelection(nil)
        if let region, region.width >= 8, region.height >= 8 { overlay.select(screen, target: .display(region: region)) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: overlay.select(screen, target: .display(region: nil))
        case 49:
            guard !event.isARepeat else { return }
            origin = nil
            windowClickStarted = false
            overlay.toggleWindowMode()
        case 53: overlay.dismiss()
        default: super.keyDown(with: event)
        }
    }

    fileprivate func refreshWindowHighlight() {
        let mouse = NSEvent.mouseLocation
        guard selection.windowMode, let target = overlay.window(at: mouse) else {
            updateSelection(nil)
            return
        }
        let frame = target.frame
        let local = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                           width: frame.width, height: frame.height).intersection(bounds)
        updateSelection(local.isNull ? nil : local)
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

private struct RecordingSelectionToolbar: View {
    @Bindable var selection: RecordingSelection
    let toggleWindowMode: () -> Void
    let fullScreen: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text(selection.windowMode ? selection.windowPrompt : "Drag to select an area")
                    .textStyle(.bodyStrong)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
                Button(action: toggleWindowMode) {
                    HStack(spacing: Space.xs) {
                        Text("Window").hidden()
                            .overlay(alignment: .leading) {
                                Text(selection.windowMode ? "Area" : "Window").fixedSize()
                            }
                        Kbd(keys: "Space").accessibilityHidden(true)
                    }
                }
                .buttonStyle(.shad(.ghost, size: .sm))
                .accessibilityLabel(selection.windowMode ? "Select an area" : "Select a window")
                .help(selection.windowMode ? "Switch to area selection (Space)" : "Switch to window selection (Space)")
                ShadSeparator(vertical: true).frame(height: Space.lg)
                Button("Full Screen", systemImage: "display", action: fullScreen)
                    .buttonStyle(.shad(.primary, size: .sm))
                IconButton(symbol: "xmark", help: "Cancel", size: .iconSm, action: cancel)
            }
            .fixedSize()
            .padding(.leading, Space.md)
            .padding(.trailing, Space.sm)
            .padding(.vertical, Space.sm)

            ShadSeparator()

            HStack(spacing: Space.xl) {
                Toggle(isOn: $selection.options.system) { Text("System Audio").textStyle(.label) }
                    .fixedSize()
                    .help(selection.windowMode ? "Record audio from the selected window’s app" : "Record audio playing on your Mac")
                Toggle(isOn: $selection.options.microphone) { Text("Microphone").textStyle(.label) }
                    .fixedSize()
                    .help("Record from your Mac’s default microphone")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
        .fixedSize()
        .recordingPanelChrome()
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
