import AppKit
import SwiftUI

@MainActor
@Observable
final class EditorModel {
    let record: CaptureRecord
    let image: CGImage
    let pointScale: CGFloat

    var document: EditorDocument
    var tool: EditorTool = .arrow
    var selection: UUID?
    var editingTextID: UUID?

    var color: RGBA = RGBA.palette[0].color
    var sizeIndex = 1
    var shapeFilled = false
    var redactStyle: RedactStyle = .pixelate
    var textStyle: TextStyleKind = .plain

    var zoom: CGFloat = 1
    var fitsWindow = true
    var showsBackgroundPanel = false

    /// Crop being edited while the crop tool is active.
    var pendingCrop: CGRect?

    private(set) var effects = EffectImages()
    @ObservationIgnored private var undoStack: [EditorDocument] = []
    @ObservationIgnored private var redoStack: [EditorDocument] = []
    @ObservationIgnored private var gestureStart: EditorDocument?
    @ObservationIgnored private var drag: DragOperation = .none
    @ObservationIgnored private var savedDocument: EditorDocument
    private(set) var canUndo = false
    private(set) var canRedo = false

    enum Handle: Hashable {
        case start, end, topLeft, topRight, bottomLeft, bottomRight
    }

    private enum DragOperation {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Handle)
        case cropNew(origin: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(Handle)
    }

    init(record: CaptureRecord, image: CGImage, document: EditorDocument?) {
        self.record = record
        self.image = image
        self.pointScale = CGFloat(record.scale)
        let doc = document ?? EditorDocument()
        self.document = doc
        self.savedDocument = doc
        if let last = doc.annotations.last(where: { $0.kind != .redact && $0.kind != .spotlight }) {
            color = last.color
        }
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var hasChanges: Bool { document != savedDocument }

    func markSaved() { savedDocument = document }

    /// Visible region of the image in pixels.
    var contentRect: CGRect {
        if tool == .crop { return CGRect(origin: .zero, size: imageSize) }
        return document.crop ?? CGRect(origin: .zero, size: imageSize)
    }

    var strokeWidth: CGFloat { [3, 5, 8][sizeIndex] * pointScale }

    var nextCounter: Int {
        (document.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    func loadEffects() async {
        guard effects.pixelated == nil else { return }
        let source = image
        effects = await Task.detached(priority: .userInitiated) { EffectImages.make(from: source) }.value
    }

    // MARK: Undo

    private func pushUndo(_ snapshot: EditorDocument) {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoState()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selection = nil
        refreshUndoState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        selection = nil
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    @ObservationIgnored private var lastCoalesce: (key: String, time: Date)?

    /// Applies a discrete change as one undo step. Rapid changes sharing a `coalescing` key
    /// (e.g. dragging a slider) collapse into a single step.
    func change(coalescing key: String? = nil, _ body: (inout EditorDocument) -> Void) {
        let before = document
        body(&document)
        guard document != before else { return }
        if let key, let last = lastCoalesce, last.key == key, Date().timeIntervalSince(last.time) < 0.6 {
            lastCoalesce = (key, Date())
            return
        }
        lastCoalesce = key.map { ($0, Date()) }
        pushUndo(before)
    }

    // MARK: Tools & styles

    func select(tool newTool: EditorTool) {
        commitTextEditing()
        if tool == .crop && newTool != .crop { pendingCrop = nil }
        tool = newTool
        if newTool == .crop {
            selection = nil
            pendingCrop = document.crop ?? CGRect(origin: .zero, size: imageSize)
        }
        if newTool == .redact || newTool == .spotlight { Task { await loadEffects() } }
    }

    func applyColor(_ newColor: RGBA) {
        color = newColor
        updateSelected { $0.color = newColor }
    }

    func applySize(_ index: Int) {
        sizeIndex = index
        let width = strokeWidth
        updateSelected { $0.size = width }
    }

    func applyFilled(_ filled: Bool) {
        shapeFilled = filled
        updateSelected { if $0.kind == .rectangle || $0.kind == .ellipse { $0.filled = filled } }
    }

    func applyRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        updateSelected { if $0.kind == .redact { $0.redactStyle = style } }
    }

    func applyTextStyle(_ style: TextStyleKind) {
        textStyle = style
        updateSelected { if $0.kind == .text { $0.textStyle = style } }
    }

    private func updateSelected(_ body: (inout Annotation) -> Void) {
        guard let id = selection else { return }
        change { doc in
            if let index = doc.annotations.firstIndex(where: { $0.id == id }) { body(&doc.annotations[index]) }
        }
    }

    var selectedAnnotation: Annotation? {
        guard let selection else { return nil }
        return document.annotations.first { $0.id == selection }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        change { $0.annotations.removeAll { $0.id == id } }
        selection = nil
    }

    func bringSelectionForward() {
        guard let id = selection else { return }
        change { doc in
            if let index = doc.annotations.firstIndex(where: { $0.id == id }) {
                let item = doc.annotations.remove(at: index)
                doc.annotations.append(item)
            }
        }
    }

    // MARK: Crop

    func applyCrop() {
        guard let crop = pendingCrop?.integral else { return }
        let full = CGRect(origin: .zero, size: imageSize)
        let clamped = crop.intersection(full)
        change { $0.crop = clamped == full || clamped.width < 8 || clamped.height < 8 ? nil : clamped }
        pendingCrop = nil
        tool = .select
    }

    func cancelCrop() {
        pendingCrop = nil
        tool = .select
    }

    func resetCrop() {
        pendingCrop = CGRect(origin: .zero, size: imageSize)
    }

    // MARK: Text editing

    func commitTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let annotation = document.annotations.first(where: { $0.id == id }),
           annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.annotations.removeAll { $0.id == id }
            selection = nil
        }
        finishGesture()
    }

    func binding(forText id: UUID) -> Binding<String> {
        Binding(
            get: { self.document.annotations.first { $0.id == id }?.text ?? "" },
            set: { value in
                if let index = self.document.annotations.firstIndex(where: { $0.id == id }) {
                    self.document.annotations[index].text = value
                }
            }
        )
    }

    // MARK: Pointer

    func handleRadius() -> CGFloat { 6 / max(zoom, 0.0001) }

    func pointerDown(at point: CGPoint, clickCount: Int) {
        if editingTextID != nil {
            commitTextEditing()
            if tool == .text { return }
        }
        gestureStart = document

        if tool == .crop {
            beginCropDrag(at: point)
            return
        }

        // Handles of the current selection win over everything.
        if let selected = selectedAnnotation, let handle = hitHandle(of: selected, at: point) {
            drag = .resizing(selected.id, handle)
            return
        }

        // Drawing tools only grab shapes of their own kind, so you can draw on top of others.
        let grabbable: Annotation.Kind? = tool == .select ? nil : tool.annotationKind
        if let hit = hitTest(point, kind: grabbable) {
            selection = hit.id
            if hit.kind == .text && (clickCount >= 2 || tool == .text) {
                editingTextID = hit.id
                drag = .none
                return
            }
            drag = .moving(hit.id, last: point)
            syncStyle(from: hit)
            return
        }

        guard let kind = tool.annotationKind else {
            selection = nil
            drag = .none
            return
        }

        var annotation = Annotation(kind: kind, start: point, end: point, color: color, size: strokeWidth)
        annotation.filled = shapeFilled
        annotation.redactStyle = redactStyle
        annotation.textStyle = textStyle
        switch kind {
        case .pen, .marker:
            annotation.points = [point]
        case .counter:
            annotation.number = nextCounter
        case .text:
            annotation.start = CGPoint(x: point.x, y: point.y - annotation.fontSize * 0.6)
        default:
            break
        }
        document.annotations.append(annotation)
        selection = annotation.id

        switch kind {
        case .counter:
            drag = .moving(annotation.id, last: point)
        case .text:
            editingTextID = annotation.id
            drag = .none
        default:
            drag = .creating(annotation.id)
        }
    }

    func pointerDragged(to point: CGPoint, shift: Bool) {
        switch drag {
        case .none:
            return
        case let .creating(id):
            mutate(id) { a in
                switch a.kind {
                case .pen, .marker:
                    if shift, let first = a.points.first {
                        a.points = [first, point]
                    } else if let last = a.points.last, hypot(point.x - last.x, point.y - last.y) > 1.5 / max(zoom, 0.01) {
                        a.points.append(point)
                    }
                case .arrow, .line:
                    a.end = shift ? snapAngle(from: a.start, to: point) : point
                default:
                    a.end = shift ? squared(from: a.start, to: point) : point
                }
            }
        case let .moving(id, last):
            let delta = CGSize(width: point.x - last.x, height: point.y - last.y)
            mutate(id) { $0.offset(by: delta) }
            drag = .moving(id, last: point)
        case let .resizing(id, handle):
            mutate(id) { a in resize(&a, handle: handle, to: point, shift: shift) }
        case let .cropNew(origin):
            pendingCrop = clampToImage(CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y)))
        case let .cropMove(last):
            guard var crop = pendingCrop else { return }
            crop.origin.x = min(max(crop.origin.x + point.x - last.x, 0), imageSize.width - crop.width)
            crop.origin.y = min(max(crop.origin.y + point.y - last.y, 0), imageSize.height - crop.height)
            pendingCrop = crop
            drag = .cropMove(last: point)
        case let .cropResize(handle):
            guard let crop = pendingCrop else { return }
            var minX = crop.minX, minY = crop.minY, maxX = crop.maxX, maxY = crop.maxY
            switch handle {
            case .topLeft: minX = point.x; minY = point.y
            case .topRight: maxX = point.x; minY = point.y
            case .bottomLeft: minX = point.x; maxY = point.y
            case .bottomRight, .end, .start: maxX = point.x; maxY = point.y
            }
            pendingCrop = clampToImage(CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)))
        }
    }

    func pointerUp() {
        if case let .creating(id) = drag, let annotation = document.annotations.first(where: { $0.id == id }) {
            // Discard accidental clicks that produced no visible shape.
            let tiny: Bool
            switch annotation.kind {
            case .pen, .marker: tiny = annotation.points.count < 2
            case .arrow, .line: tiny = hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y) < 4 * pointScale
            default: tiny = annotation.rect.width < 3 * pointScale || annotation.rect.height < 3 * pointScale
            }
            if tiny {
                document.annotations.removeAll { $0.id == id }
                selection = nil
            }
        }
        drag = .none
        if editingTextID == nil { finishGesture() }
    }

    private func finishGesture() {
        if let start = gestureStart, start != document { pushUndo(start) }
        gestureStart = nil
    }

    private func mutate(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&document.annotations[index])
    }

    private func syncStyle(from annotation: Annotation) {
        if annotation.kind != .redact && annotation.kind != .spotlight { color = annotation.color }
        if let index = [3, 5, 8].map({ $0 * pointScale }).firstIndex(where: { abs($0 - annotation.size) < 0.5 }) { sizeIndex = index }
        if annotation.kind == .rectangle || annotation.kind == .ellipse { shapeFilled = annotation.filled }
        if annotation.kind == .redact { redactStyle = annotation.redactStyle }
        if annotation.kind == .text { textStyle = annotation.textStyle }
    }

    // MARK: Hit testing

    func hitTest(_ point: CGPoint, kind: Annotation.Kind? = nil) -> Annotation? {
        let tolerance = max(8 / max(zoom, 0.01), 4)
        for annotation in document.annotations.reversed() {
            if let kind, annotation.kind != kind, annotation.id != selection { continue }
            if contains(annotation, point, tolerance: tolerance) { return annotation }
        }
        return nil
    }

    private func contains(_ a: Annotation, _ point: CGPoint, tolerance: CGFloat) -> Bool {
        let stroke = StrokeStyle(lineWidth: a.size + tolerance * 2, lineCap: .round, lineJoin: .round)
        switch a.kind {
        case .arrow, .line:
            var path = Path()
            path.move(to: a.start)
            path.addLine(to: a.end)
            return path.strokedPath(stroke).contains(point)
        case .rectangle:
            return a.filled ? a.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) : Path(a.rect).strokedPath(stroke).contains(point)
        case .ellipse:
            return a.filled ? Path(ellipseIn: a.rect).contains(point) : Path(ellipseIn: a.rect).strokedPath(stroke).contains(point)
        case .pen:
            return AnnotationRenderer.smoothPath(a.points).strokedPath(stroke).contains(point)
        case .marker:
            let wide = StrokeStyle(lineWidth: a.size * 4 + tolerance * 2, lineCap: .round, lineJoin: .round)
            return AnnotationRenderer.smoothPath(a.points).strokedPath(wide).contains(point)
        case .text, .counter, .redact, .spotlight:
            return a.bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point)
        }
    }

    func handles(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow, .line:
            return [(.start, a.start), (.end, a.end)]
        case .rectangle, .ellipse, .redact, .spotlight:
            let r = a.rect
            return [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            ]
        default:
            return []
        }
    }

    func cropHandles(_ crop: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: crop.minX, y: crop.minY)), (.topRight, CGPoint(x: crop.maxX, y: crop.minY)),
            (.bottomLeft, CGPoint(x: crop.minX, y: crop.maxY)), (.bottomRight, CGPoint(x: crop.maxX, y: crop.maxY)),
        ]
    }

    private func hitHandle(of a: Annotation, at point: CGPoint) -> Handle? {
        let radius = handleRadius() * 1.8
        return handles(for: a).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }?.0
    }

    private func beginCropDrag(at point: CGPoint) {
        let crop = pendingCrop ?? CGRect(origin: .zero, size: imageSize)
        let radius = handleRadius() * 2.2
        if let handle = cropHandles(crop).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius })?.0 {
            drag = .cropResize(handle)
        } else if crop.contains(point) && crop.size != imageSize {
            drag = .cropMove(last: point)
        } else {
            drag = .cropNew(origin: point)
        }
    }

    private func resize(_ a: inout Annotation, handle: Handle, to point: CGPoint, shift: Bool) {
        switch handle {
        case .start: a.start = shift ? snapAngle(from: a.end, to: point) : point
        case .end: a.end = shift ? snapAngle(from: a.start, to: point) : point
        default:
            let r = a.rect
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch handle {
            case .topLeft: minX = point.x; minY = point.y
            case .topRight: maxX = point.x; minY = point.y
            case .bottomLeft: minX = point.x; maxY = point.y
            default: maxX = point.x; maxY = point.y
            }
            a.start = CGPoint(x: minX, y: minY)
            a.end = CGPoint(x: maxX, y: maxY)
        }
    }

    private func clampToImage(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func squared(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let side = max(abs(point.x - start.x), abs(point.y - start.y))
        return CGPoint(x: start.x + (point.x >= start.x ? side : -side), y: start.y + (point.y >= start.y ? side : -side))
    }

    /// Snaps to 45° increments.
    private func snapAngle(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
}
