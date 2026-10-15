import AppKit
import SwiftUI

/// Floating, always-on-top screenshots. Drag to move, scroll or pinch to zoom, Esc to close.
@MainActor
final class PinController {
    static let shared = PinController()

    private var panels: [PinPanel] = []

    func pin(image: CGImage, scale: CGFloat, recordID: UUID?) {
        let screen = NSScreen.withMouse ?? NSScreen.main!
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, visible.width / size.width, visible.height / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)

        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

        let panel = PinPanel(image: image, scale: scale, recordID: recordID, frame: CGRect(origin: origin, size: size))
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func closeAll() {
        for panel in panels { panel.close() }
    }
}

final class PinPanel: NSPanel {
    let image: CGImage
    let scale: CGFloat
    let recordID: UUID?
    var onClose: (() -> Void)?
    private let aspect: CGFloat
    private var opacityLevel: CGFloat = 1

    init(image: CGImage, scale: CGFloat, recordID: UUID?, frame: CGRect) {
        self.image = image
        self.scale = scale
        self.recordID = recordID
        self.aspect = CGFloat(image.width) / CGFloat(image.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinContentView(panel: self)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers ?? "", command) {
        case ("w", true): close()
        case ("c", true): copyImage()
        case ("0", true): resetSize()
        case ("=", true), ("+", true): zoom(by: 1.15, around: nil)
        case ("-", true): zoom(by: 1 / 1.15, around: nil)
        default:
            if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
        }
    }

    func zoom(by factor: CGFloat, around point: CGPoint?) {
        let current = frame
        let natural = CGFloat(image.width) / scale
        var width = current.width * factor
        width = min(max(width, 60), natural * 4)
        let height = width / aspect
        let anchor = point ?? CGPoint(x: current.midX, y: current.midY)
        let fx = (anchor.x - current.minX) / current.width
        let fy = (anchor.y - current.minY) / current.height
        let newFrame = CGRect(x: anchor.x - width * fx, y: anchor.y - height * fy, width: width, height: height)
        setFrame(newFrame, display: true)
    }

    func resetSize() {
        let width = CGFloat(image.width) / scale
        zoom(by: width / frame.width, around: nil)
    }

    func setOpacity(_ value: CGFloat) {
        opacityLevel = value
        animator().alphaValue = value
    }

    func copyImage() {
        Clipboard.copy(image: image, scale: scale)
        ToastCenter.shared.show(.success, "Copied to clipboard")
    }

    func annotate() {
        guard let recordID, let record = HistoryStore.shared.record(recordID) else { return }
        AppController.shared.annotate(record)
        close()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Copy", keyEquivalent: "c") { [weak self] in self?.copyImage() })
        if recordID != nil {
            menu.addItem(ClosureMenuItem(title: "Annotate") { [weak self] in self?.annotate() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Actual Size", keyEquivalent: "0") { [weak self] in self?.resetSize() })
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for value in [1.0, 0.75, 0.5, 0.25] {
            let item = ClosureMenuItem(title: "\(Int(value * 100))%") { [weak self] in self?.setOpacity(value) }
            item.state = abs(opacityLevel - value) < 0.01 ? .on : .off
            submenu.addItem(item)
        }
        opacity.submenu = submenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close", keyEquivalent: "w") { [weak self] in self?.close() })
        menu.font = Jakarta.nsFont(13)
        return menu
    }
}

/// Draws the pinned image and handles moving, zooming and the hover close button.
private final class PinContentView: NSView {
    private weak var panel: PinPanel?
    private let closeButton: NSHostingView<PinCloseButton>

    init(panel: PinPanel) {
        self.panel = panel
        closeButton = NSHostingView(rootView: PinCloseButton { [weak panel] in panel?.close() })
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = panel.image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.minificationFilter = .trilinear

        closeButton.alphaValue = 0
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: 6, y: bounds.height - 30, width: 24, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setCloseVisible(true) }
    override func mouseExited(with event: NSEvent) { setCloseVisible(false) }

    private func setCloseVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        panel?.makeKey()
        if event.clickCount == 2 {
            panel?.annotate()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        panel?.zoom(by: 1 + delta / 300, around: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        panel?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? { panel?.makeMenu() }
}

private struct PinCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}
