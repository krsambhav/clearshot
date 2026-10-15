import AppKit
import QuartzCore
import SwiftUI

enum CapturePurpose {
    case screenshot, text
}

enum OverlayOutcome {
    /// `pixelRect` is in the snapshot image's pixel space (top-left origin).
    case region(DisplaySnapshot, pixelRect: CGRect)
    case window(WindowTarget, DisplaySnapshot?)
    case cancelled
}

/// Presents a frozen copy of every display and lets the user pick an area or a window.
/// Built on Core Animation so the marquee and loupe track the pointer every frame.
@MainActor
final class CaptureOverlayController {
    let purpose: CapturePurpose
    private(set) var windowPicking: Bool
    let session: CaptureSession

    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private var completion: ((OverlayOutcome) -> Void)?

    init(session: CaptureSession, purpose: CapturePurpose, startInWindowMode: Bool, completion: @escaping (OverlayOutcome) -> Void) {
        self.session = session
        self.purpose = purpose
        self.windowPicking = startInWindowMode
        self.completion = completion
    }

    func present() {
        let mouse = NSEvent.mouseLocation
        for snapshot in session.displays {
            let panel = OverlayPanel(screen: snapshot.screen)
            let view = OverlayView(snapshot: snapshot, controller: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if snapshot.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
        for view in views { view.refresh(mouseInGlobal: mouse) }
        NSCursor.crosshair.set()
    }

    func toggleWindowPicking() {
        windowPicking.toggle()
        let mouse = NSEvent.mouseLocation
        for view in views { view.modeChanged(mouseInGlobal: mouse) }
    }

    func focus(_ view: OverlayView) {
        guard let panel = view.window as? OverlayPanel, !panel.isKeyWindow else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    func pointerMoved(globalPoint: CGPoint, from source: OverlayView) {
        for view in views where view !== source {
            view.refresh(mouseInGlobal: globalPoint)
        }
    }

    func window(at globalPoint: CGPoint) -> WindowTarget? {
        session.windows.first { $0.frame.contains(globalPoint) }
    }

    func finish(_ outcome: OverlayOutcome) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(outcome)
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay view

/// Coordinates: the view is not flipped, so layer geometry is bottom-left like Core Animation.
/// Pixel math against the snapshot (top-left origin) goes through `pixelRect(for:)`.
@MainActor
final class OverlayView: NSView {
    private let snapshot: DisplaySnapshot
    private unowned let controller: CaptureOverlayController

    private let imageLayer = CALayer()
    private let scrimLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let windowLayer = CAShapeLayer()
    private let sizeChip = ChipLayer()
    private let magnifier = MagnifierLayer()
    private var hint: NSView?

    private var mouse: CGPoint?
    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var movingSelection = false
    private var lastMovePoint: CGPoint?
    private var hoveredWindow: WindowTarget?

    init(snapshot: DisplaySnapshot, controller: CaptureOverlayController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setUpLayers()
        installHint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { snapshot.scale }
    private var isDragging: Bool { dragOrigin != nil }

    // MARK: Layers

    private func setUpLayers() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        imageLayer.frame = bounds
        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = scale
        root.addSublayer(imageLayer)

        scrimLayer.frame = bounds
        scrimLayer.fillRule = .evenOdd
        scrimLayer.fillColor = Theme.scrim.cgColor
        root.addSublayer(scrimLayer)

        windowLayer.fillColor = Theme.nsBrand.withAlphaComponent(0.16).cgColor
        windowLayer.strokeColor = Theme.nsBrand.cgColor
        windowLayer.lineWidth = 2
        root.addSublayer(windowLayer)

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1 / scale
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOpacity = 0.35
        crosshairLayer.shadowRadius = 0
        crosshairLayer.shadowOffset = CGSize(width: 0, height: -1 / scale)
        crosshairLayer.contentsScale = scale
        root.addSublayer(crosshairLayer)

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = Theme.overlayInk.cgColor
        selectionLayer.lineWidth = 1
        selectionLayer.shadowColor = NSColor.black.cgColor
        selectionLayer.shadowOpacity = 0.45
        selectionLayer.shadowRadius = 1.5
        selectionLayer.shadowOffset = .zero
        root.addSublayer(selectionLayer)

        sizeChip.contentsScale = scale
        sizeChip.isHidden = true
        root.addSublayer(sizeChip)

        magnifier.configure(scale: scale)
        magnifier.isHidden = true
        root.addSublayer(magnifier)

        for layer in [scrimLayer, crosshairLayer, selectionLayer, windowLayer, sizeChip, magnifier] as [CALayer] {
            layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "contents": NSNull()]
        }
    }

    private func installHint() {
        let content = OverlayHint(purpose: controller.purpose, windowMode: controller.windowPicking)
        let host = PassthroughHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = CGRect(x: (bounds.width - size.width) / 2, y: 40, width: size.width, height: size.height)
        addSubview(host)
        hint = host

        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2.4))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                host?.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    private func hideHint() {
        guard let hint, hint.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hint.animator().alphaValue = 0
        }
    }

    // MARK: State → layers

    func refresh(mouseInGlobal global: CGPoint) {
        let local = CGPoint(x: global.x - snapshot.frame.minX, y: global.y - snapshot.frame.minY)
        mouse = bounds.contains(local) ? local : nil
        if controller.windowPicking { hoveredWindow = controller.window(at: global) }
        render()
    }

    func modeChanged(mouseInGlobal global: CGPoint) {
        dragOrigin = nil
        dragCurrent = nil
        hideHint()
        refresh(mouseInGlobal: global)
        updateCursor()
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = CGPath(rect: bounds, transform: nil)

        if controller.windowPicking {
            crosshairLayer.isHidden = true
            selectionLayer.isHidden = true
            sizeChip.isHidden = true
            magnifier.isHidden = true
            if let window = hoveredWindow {
                let rect = window.frame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY).intersection(bounds)
                let rounded = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil)
                windowLayer.path = rounded
                windowLayer.isHidden = rect.isNull
                let scrim = CGMutablePath()
                scrim.addPath(full)
                scrim.addPath(rounded)
                scrimLayer.path = scrim
                scrimLayer.opacity = 0.8
            } else {
                windowLayer.isHidden = true
                scrimLayer.path = full
                scrimLayer.opacity = 0.8
            }
            return
        }

        windowLayer.isHidden = true

        if let selection = selectionRect, selection.width >= 1, selection.height >= 1 {
            let scrim = CGMutablePath()
            scrim.addPath(full)
            scrim.addRect(selection)
            scrimLayer.path = scrim
            scrimLayer.opacity = 1
            selectionLayer.isHidden = false
            selectionLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            crosshairLayer.isHidden = true
            layoutSizeChip(for: selection)
        } else {
            scrimLayer.path = full
            scrimLayer.opacity = 0.3
            selectionLayer.isHidden = true
            sizeChip.isHidden = true
            if let mouse, Preferences.shared.showCrosshair {
                let path = CGMutablePath()
                let x = (mouse.x * scale).rounded(.down) / scale + 0.5 / scale
                let y = (mouse.y * scale).rounded(.down) / scale + 0.5 / scale
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: bounds.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
                crosshairLayer.path = path
                crosshairLayer.isHidden = false
            } else {
                crosshairLayer.isHidden = true
            }
        }

        if let mouse, Preferences.shared.showMagnifier, !movingSelection {
            magnifier.isHidden = false
            magnifier.update(image: snapshot.image, pixel: pixelPoint(for: mouse), viewPoint: mouse, in: bounds)
        } else {
            magnifier.isHidden = true
        }
    }

    private func layoutSizeChip(for selection: CGRect) {
        let pixels = pixelRect(for: selection)
        let factor = Preferences.shared.downscaleRetina ? scale : 1
        let text = "\(Int(pixels.width / factor)) × \(Int(pixels.height / factor))"
        sizeChip.setText(text)
        let size = sizeChip.preferredFrameSize()
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - size.height - 8)
        if origin.y < 8 { origin.y = selection.minY + 8 }
        origin.x = min(max(origin.x, 8), bounds.width - size.width - 8)
        sizeChip.frame = CGRect(origin: origin, size: size)
        sizeChip.isHidden = false
    }

    private var selectionRect: CGRect? {
        guard let origin = dragOrigin, let current = dragCurrent else { return nil }
        var end = current
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            let side = max(abs(end.x - origin.x), abs(end.y - origin.y))
            end = CGPoint(x: origin.x + (end.x >= origin.x ? side : -side), y: origin.y + (end.y >= origin.y ? side : -side))
        }
        var rect: CGRect
        if flags.contains(.option) {
            let dx = abs(end.x - origin.x)
            let dy = abs(end.y - origin.y)
            rect = CGRect(x: origin.x - dx, y: origin.y - dy, width: dx * 2, height: dy * 2)
        } else {
            rect = CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y), width: abs(end.x - origin.x), height: abs(end.y - origin.y))
        }
        rect = rect.intersection(bounds)
        guard !rect.isNull else { return nil }
        // Snap to device pixels so the marquee and the crop agree exactly.
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pixelRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX * scale).rounded(),
            y: ((bounds.height - rect.maxY) * scale).rounded(),
            width: (rect.width * scale).rounded(),
            height: (rect.height * scale).rounded()
        )
    }

    private func pixelPoint(for point: CGPoint) -> (x: Int, y: Int) {
        (Int((point.x * scale).rounded(.down)), Int(((bounds.height - point.y) * scale).rounded(.down)))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func updateCursor() {
        (controller.windowPicking ? NSCursor.pointingHand : NSCursor.crosshair).set()
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func mouseEntered(with event: NSEvent) {
        controller.focus(self)
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        mouse = nil
        render()
    }

    override func mouseMoved(with event: NSEvent) {
        controller.focus(self)
        updateCursor()
        let global = NSEvent.mouseLocation
        refresh(mouseInGlobal: global)
        controller.pointerMoved(globalPoint: global, from: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        mouse = point
        if controller.windowPicking { return }
        dragOrigin = point
        dragCurrent = point
        lastMovePoint = point
        hideHint()
        render()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !controller.windowPicking, dragOrigin != nil else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        if movingSelection, let last = lastMovePoint, let origin = dragOrigin, let current = dragCurrent {
            let dx = point.x - last.x
            let dy = point.y - last.y
            dragOrigin = CGPoint(x: origin.x + dx, y: origin.y + dy)
            dragCurrent = CGPoint(x: current.x + dx, y: current.y + dy)
        } else {
            dragCurrent = point
        }
        lastMovePoint = point
        mouse = point
        render()
    }

    override func mouseUp(with event: NSEvent) {
        if controller.windowPicking {
            let global = NSEvent.mouseLocation
            if let target = controller.window(at: global) {
                controller.finish(.window(target, snapshot))
            }
            return
        }
        guard let selection = selectionRect else { return }
        dragOrigin = nil
        dragCurrent = nil
        movingSelection = false
        if selection.width < 4 || selection.height < 4 {
            render()
            return
        }
        controller.finish(.region(snapshot, pixelRect: pixelRect(for: selection)))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.finish(.cancelled)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            if isDragging {
                dragOrigin = nil
                dragCurrent = nil
                render()
            } else {
                controller.finish(.cancelled)
            }
        case 49: // Space
            if isDragging {
                movingSelection = true
            } else if !event.isARepeat {
                controller.toggleWindowPicking()
            }
        case 36, 76: // Return: capture the screen under the pointer
            if !isDragging {
                controller.finish(.region(snapshot, pixelRect: CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)))
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { movingSelection = false; render() }
    }

    override func flagsChanged(with event: NSEvent) {
        render()
    }
}

// MARK: - Layers

/// Small dark pill with tabular figures.
nonisolated final class ChipLayer: CALayer {
    private let textLayer = CATextLayer()
    private var attributed = NSAttributedString()

    override init() {
        super.init()
        backgroundColor = Theme.overlayChip.cgColor
        cornerRadius = 6
        cornerCurve = .continuous
        borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        borderWidth = 1
        textLayer.alignmentMode = .center
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSublayer(textLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet { textLayer.contentsScale = contentsScale }
    }

    func setText(_ text: String) {
        attributed = NSAttributedString(string: text, attributes: [
            .font: Jakarta.nsFont(11, .semibold, tabular: true),
            .foregroundColor: Theme.overlayInk,
        ])
        textLayer.string = attributed
        setNeedsLayout()
    }

    override func preferredFrameSize() -> CGSize {
        let size = attributed.size()
        return CGSize(width: ceil(size.width) + 16, height: 22)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let size = attributed.size()
        textLayer.frame = CGRect(x: 0, y: (bounds.height - ceil(size.height)) / 2, width: bounds.width, height: ceil(size.height))
    }
}

/// Pixel loupe: shows a 15×15 pixel neighbourhood at 8× with a centre marker and coordinates.
nonisolated final class MagnifierLayer: CALayer {
    private let pixelsAcross = 15
    private let cell: CGFloat = 8
    private let lens = CALayer()
    private let content = CALayer()
    private let grid = CAShapeLayer()
    private let marker = CAShapeLayer()
    private let chip = ChipLayer()

    private var lensSize: CGFloat { CGFloat(pixelsAcross) * cell }

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(scale: CGFloat) {
        contentsScale = scale

        lens.frame = CGRect(x: 0, y: 26 + 6, width: lensSize, height: lensSize)
        lens.cornerRadius = 12
        lens.cornerCurve = .continuous
        lens.masksToBounds = true
        lens.backgroundColor = NSColor.black.cgColor
        lens.borderWidth = 1
        lens.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        addSublayer(lens)

        content.magnificationFilter = .nearest
        content.contentsGravity = .resize
        lens.addSublayer(content)

        let gridPath = CGMutablePath()
        for i in 1 ..< pixelsAcross {
            let p = CGFloat(i) * cell
            gridPath.move(to: CGPoint(x: p, y: 0)); gridPath.addLine(to: CGPoint(x: p, y: lensSize))
            gridPath.move(to: CGPoint(x: 0, y: p)); gridPath.addLine(to: CGPoint(x: lensSize, y: p))
        }
        grid.path = gridPath
        grid.strokeColor = NSColor.black.withAlphaComponent(0.08).cgColor
        grid.lineWidth = 1 / scale
        grid.frame = lens.bounds
        lens.addSublayer(grid)

        let center = CGFloat(pixelsAcross / 2) * cell
        marker.path = CGPath(rect: CGRect(x: center, y: center, width: cell, height: cell), transform: nil)
        marker.fillColor = nil
        marker.strokeColor = NSColor.white.cgColor
        marker.lineWidth = 1.5
        marker.shadowColor = NSColor.black.cgColor
        marker.shadowOpacity = 0.6
        marker.shadowRadius = 0.5
        marker.shadowOffset = .zero
        marker.frame = lens.bounds
        lens.addSublayer(marker)

        chip.contentsScale = scale
        addSublayer(chip)

        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.3
        shadowRadius = 10
        shadowOffset = CGSize(width: 0, height: -4)

        bounds = CGRect(x: 0, y: 0, width: lensSize, height: lensSize + 32)
        anchorPoint = .zero

        for layer in [lens, content, grid, marker, chip] as [CALayer] {
            layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        }
    }

    func update(image: CGImage, pixel: (x: Int, y: Int), viewPoint: CGPoint, in container: CGRect) {
        let half = pixelsAcross / 2
        let want = CGRect(x: pixel.x - half, y: pixel.y - half, width: pixelsAcross, height: pixelsAcross)
        let have = want.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !have.isNull, let crop = image.cropping(to: have) {
            content.contents = crop
            // Image rows run top-down; layer y runs bottom-up.
            content.frame = CGRect(
                x: (have.minX - want.minX) * cell,
                y: (want.maxY - have.maxY) * cell,
                width: have.width * cell,
                height: have.height * cell
            )
        }

        chip.setText("\(pixel.x), \(pixel.y)")
        let chipSize = chip.preferredFrameSize()
        chip.frame = CGRect(x: (lensSize - chipSize.width) / 2, y: 0, width: chipSize.width, height: chipSize.height)

        let gap: CGFloat = 22
        var origin = CGPoint(x: viewPoint.x + gap, y: viewPoint.y - gap - bounds.height)
        if origin.x + bounds.width > container.maxX - 8 { origin.x = viewPoint.x - gap - bounds.width }
        if origin.y < container.minY + 8 { origin.y = viewPoint.y + gap }
        position = origin
    }
}

/// Hosting view that never intercepts the pointer.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct OverlayHint: View {
    let purpose: CapturePurpose
    let windowMode: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Text(purpose == .text ? "Select text to copy" : (windowMode ? "Click a window" : "Drag to capture"))
                .textStyle(.label)
                .foregroundStyle(Theme.foreground)
            ShadSeparator(vertical: true).frame(height: 14)
            HStack(spacing: 6) {
                Kbd(keys: "Space")
                Text(windowMode ? "Area" : "Window").textStyle(.footnote).foregroundStyle(Theme.mutedForeground)
            }
            HStack(spacing: 6) {
                Kbd(keys: "⇧")
                Text("Square").textStyle(.footnote).foregroundStyle(Theme.mutedForeground)
            }
            HStack(spacing: 6) {
                Kbd(keys: "esc")
                Text("Cancel").textStyle(.footnote).foregroundStyle(Theme.mutedForeground)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Theme.popover.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(20)
        .shadowLg()
    }
}
