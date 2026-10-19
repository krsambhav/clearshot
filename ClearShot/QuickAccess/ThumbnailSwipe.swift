import AppKit
import SwiftUI

/// Tracks physical finger direction independently of the Natural Scrolling preference.
struct ThumbnailSwipeState {
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var active = false
    private var dismissed = false

    mutating func consume(x: CGFloat, y: CGFloat, inverted: Bool, phase: NSEvent.Phase,
                          momentum: NSEvent.Phase = []) -> Bool {
        guard momentum.isEmpty else { return false }
        if phase.contains(.began) {
            horizontal = 0; vertical = 0; active = true; dismissed = false
        }
        if phase.contains(.cancelled) || phase.contains(.ended) {
            active = false
            return false
        }
        guard active, !dismissed else { return false }
        horizontal += inverted ? -x : x
        vertical += abs(y)
        guard horizontal > 48, horizontal > vertical * 1.4 else { return false }
        dismissed = true
        return true
    }
}

/// Observes only trackpad events over this card; mouse clicks and file drags pass through.
struct ThumbnailSwipeArea: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> ThumbnailSwipeView {
        let view = ThumbnailSwipeView()
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: ThumbnailSwipeView, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: ThumbnailSwipeView, coordinator: ()) { view.stopMonitoring() }
}

final class ThumbnailSwipeView: NSView {
    var dismiss: (() -> Void)?
    private var monitor: Any?
    private var swipe = ThumbnailSwipeState()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        swipe = ThumbnailSwipeState()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        if event.type == .swipe {
            // AppKit defines positive deltaX as a left swipe.
            guard event.deltaX > 0, abs(event.deltaX) > abs(event.deltaY) else { return false }
            dismiss?()
            return true
        }
        guard event.hasPreciseScrollingDeltas else { return false }
        if swipe.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                         inverted: event.isDirectionInvertedFromDevice,
                         phase: event.phase, momentum: event.momentumPhase) {
            dismiss?()
            return true
        }
        return false
    }
}
