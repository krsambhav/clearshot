import AppKit
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let actions: EditorActions

    @FocusState private var canvasFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, actions: actions)
            ShadSeparator()
            HStack(spacing: 0) {
                ZStack {
                    CanvasArea(model: model, canvasFocused: $canvasFocused)
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            Spacer()
                            OptionsBar(model: model)
                            Spacer()
                        }
                        .overlay(alignment: .bottomTrailing) { ZoomControls(model: model) }
                    }
                    .padding(Space.lg)
                }
                if model.showsBackgroundPanel {
                    ShadSeparator(vertical: true)
                    BackgroundPanel(model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
        }
        .background(Theme.muted.opacity(0.6))
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onAppear { canvasFocused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .background(shortcutButtons)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.editingTextID == nil else { return .ignored }
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .delete, .deleteForward:
            model.deleteSelection()
            return .handled
        case .escape:
            if model.tool == .crop { model.cancelCrop() } else { model.selection = nil }
            return .handled
        case .return:
            if model.tool == .crop { model.applyCrop(); return .handled }
            if let selected = model.selectedAnnotation, selected.kind == .text { model.editingTextID = selected.id; return .handled }
            return .ignored
        default:
            break
        }
        if let character = press.characters.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.key == character }) {
            withAnimation(Motion.quick) { model.select(tool: tool) }
            return .handled
        }
        if let digit = Int(press.characters), (1 ... 8).contains(digit) {
            model.applyColor(RGBA.palette[digit - 1].color)
            return .handled
        }
        return .ignored
    }

    /// Hidden buttons give the window its ⌘ shortcuts.
    private var shortcutButtons: some View {
        ZStack {
            Button("") { model.undo() }.keyboardShortcut("z", modifiers: .command)
                .disabled(model.editingTextID != nil || !model.canUndo)
            Button("") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.editingTextID != nil || !model.canRedo)
            Button("") { actions.copy() }.keyboardShortcut("c", modifiers: .command)
                .disabled(model.editingTextID != nil)
            Button("") { actions.save() }.keyboardShortcut("s", modifiers: .command)
            Button("") { model.fitsWindow = true }.keyboardShortcut("0", modifiers: .command)
            Button("") { setZoom(model.zoom * 1.25) }.keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(model.zoom / 1.25) }.keyboardShortcut("-", modifiers: .command)
            Button("") { setZoom(1 / model.pointScale) }.keyboardShortcut("1", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func setZoom(_ value: CGFloat) {
        model.fitsWindow = false
        model.zoom = min(max(value, 0.05), 8)
    }
}

struct EditorActions {
    var copy: () -> Void
    var save: () -> Void
    var dragFile: () -> URL?
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @Bindable var model: EditorModel
    let actions: EditorActions

    private let groups: [[EditorTool]] = [
        [.select],
        [.arrow, .line, .rectangle, .ellipse, .pen, .marker],
        [.text, .counter],
        [.redact, .spotlight, .crop],
    ]

    var body: some View {
        HStack(spacing: Space.sm) {
            Color.clear.frame(width: WindowMetrics.trafficLightsWidth - Space.md)
            HStack(spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        ShadSeparator(vertical: true).frame(height: 18).padding(.horizontal, 6)
                    }
                    ForEach(group) { tool in
                        ToolButton(tool: tool, active: model.tool == tool) {
                            withAnimation(Motion.quick) { model.select(tool: tool) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                    .disabled(!model.canUndo)
                IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }
                    .disabled(!model.canRedo)
            }
            ShadSeparator(vertical: true).frame(height: 18)
            IconButton(symbol: "square.on.square.squareshape.controlhandles", help: "Background", active: model.showsBackgroundPanel) {
                withAnimation(Motion.snappy) { model.showsBackgroundPanel.toggle() }
            }
            DragOutButton(actions: actions)
            Button("Copy", action: actions.copy)
                .buttonStyle(.shad(.outline, size: .sm))
            Button("Save", action: actions.save)
                .buttonStyle(.shad(.primary, size: .sm))
        }
        .padding(.horizontal, Space.md)
        .frame(height: WindowMetrics.titleBand)
        .background(Theme.background)
        .gesture(WindowDragGesture())
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Theme.brand : (hovering ? Theme.foreground : Theme.mutedForeground))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(active ? Theme.brand.opacity(0.12) : (hovering ? Theme.accent : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct DragOutButton: View {
    let actions: EditorActions
    @State private var hovering = false

    var body: some View {
        Image(systemName: "hand.draw")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(hovering ? Theme.foreground : Theme.mutedForeground)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(hovering ? Theme.accent : .clear))
            .onHover { hovering = $0 }
            .onDrag {
                guard let url = actions.dragFile() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            .help("Drag the annotated image into any app")
    }
}

// MARK: - Canvas

private struct CanvasArea: View {
    @Bindable var model: EditorModel
    var canvasFocused: FocusState<Bool>.Binding

    private let margin: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let content = model.contentRect
            let composite = compositeSize(for: content.size)
            ScrollView([.horizontal, .vertical]) {
                surface(content: content)
                    .frame(width: composite.width * model.zoom, height: composite.height * model.zoom)
                    .padding(margin)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollIndicators(.automatic)
            .onAppear { fit(in: proxy.size) }
            .onChange(of: proxy.size) { _, size in if model.fitsWindow { fit(in: size) } }
            .onChange(of: model.fitsWindow) { _, fits in if fits { fit(in: proxy.size) } }
            .onChange(of: content) { _, _ in if model.fitsWindow { fit(in: proxy.size) } }
            .onChange(of: model.document.background) { _, _ in if model.fitsWindow { fit(in: proxy.size) } }
        }
    }

    private var showsBackground: Bool { model.document.background.enabled && model.tool != .crop }

    private func compositeSize(for content: CGSize) -> CGSize {
        showsBackground ? BackgroundLayout.compositeSize(content: content, settings: model.document.background, pointScale: model.pointScale) : content
    }

    private func fit(in size: CGSize) {
        let composite = compositeSize(for: model.contentRect.size)
        let available = CGSize(width: max(size.width - margin * 2, 100), height: max(size.height - margin * 2 - 40, 100))
        let fitZoom = min(available.width / composite.width, available.height / composite.height)
        model.zoom = min(fitZoom, 1 / model.pointScale)
        model.fitsWindow = true
    }

    @ViewBuilder
    private func surface(content: CGRect) -> some View {
        if showsBackground {
            BackgroundFrame(settings: model.document.background, contentSize: content.size, pointScale: model.pointScale, unit: model.zoom) {
                EditingSurface(model: model, content: content, canvasFocused: canvasFocused)
            }
        } else {
            EditingSurface(model: model, content: content, canvasFocused: canvasFocused)
                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1).allowsHitTesting(false))
                .shadowMd()
        }
    }
}

private struct EditingSurface: View {
    @Bindable var model: EditorModel
    let content: CGRect
    var canvasFocused: FocusState<Bool>.Binding

    @State private var baseImage: NSImage?
    @State private var dragging = false

    var body: some View {
        let zoom = model.zoom
        ZStack(alignment: .topLeading) {
            if let baseImage {
                Image(nsImage: baseImage)
                    .resizable()
                    .interpolation(zoom * model.pointScale > 1.5 ? .none : .high)
                    .frame(width: model.imageSize.width * zoom, height: model.imageSize.height * zoom)
                    .offset(x: -content.minX * zoom, y: -content.minY * zoom)
            }
            AnnotatedCanvas(
                image: model.image, document: model.document, effects: model.effects,
                content: content, zoom: zoom, pointScale: model.pointScale,
                hidden: model.editingTextID, drawBase: false
            )
            SelectionLayer(model: model, content: content)
            if model.tool == .crop, let crop = model.pendingCrop {
                CropLayer(model: model, crop: crop)
            }
            if let id = model.editingTextID, let annotation = model.document.annotations.first(where: { $0.id == id }) {
                InlineTextEditor(model: model, annotation: annotation, content: content)
            }
        }
        .frame(width: content.width * zoom, height: content.height * zoom, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let point = imagePoint(value.location)
                    if !dragging {
                        dragging = true
                        canvasFocused.wrappedValue = model.editingTextID == nil
                        model.pointerDown(at: imagePoint(value.startLocation), clickCount: NSApp.currentEvent?.clickCount ?? 1)
                    }
                    model.pointerDragged(to: point, shift: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in
                    dragging = false
                    model.pointerUp()
                }
        )
        .pointerStyle(pointerStyle)
        .task {
            baseImage = NSImage(cgImage: model.image, size: model.imageSize)
            if model.document.annotations.contains(where: { $0.kind == .redact }) { await model.loadEffects() }
        }
    }

    private var pointerStyle: PointerStyle {
        switch model.tool {
        case .select: .default
        case .text: .horizontalText
        default: .rectSelection
        }
    }

    private func imagePoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x / model.zoom + content.minX, y: location.y / model.zoom + content.minY)
    }
}

/// Renders annotations (and optionally the base image) in pixel space scaled by `zoom`.
struct AnnotatedCanvas: View {
    let image: CGImage
    let document: EditorDocument
    let effects: EffectImages
    let content: CGRect
    let zoom: CGFloat
    let pointScale: CGFloat
    let hidden: UUID?
    let drawBase: Bool

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: zoom, y: zoom)
            context.translateBy(x: -content.minX, y: -content.minY)
            let size = CGSize(width: image.width, height: image.height)
            if drawBase {
                context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
            }
            AnnotationRenderer.draw(document.annotations, in: context, imageSize: size, effects: effects, pointScale: pointScale, hidden: hidden)
        }
        .allowsHitTesting(false)
    }
}

private struct SelectionLayer: View {
    let model: EditorModel
    let content: CGRect

    var body: some View {
        Canvas { context, _ in
            guard model.tool != .crop, model.editingTextID == nil, let selected = model.selectedAnnotation else { return }
            let zoom = model.zoom
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - content.minX) * zoom, y: (p.y - content.minY) * zoom) }
            let brand = Theme.brand

            let handles = model.handles(for: selected)
            if handles.isEmpty || selected.kind == .text {
                let b = selected.bounds.insetBy(dx: -4 * model.pointScale, dy: -4 * model.pointScale)
                let rect = CGRect(origin: map(b.origin), size: CGSize(width: b.width * zoom, height: b.height * zoom))
                context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(brand), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            for (_, point) in handles {
                let p = map(point)
                let circle = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                context.fill(circle, with: .color(.white))
                context.stroke(circle, with: .color(brand), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CropLayer: View {
    let model: EditorModel
    let crop: CGRect

    var body: some View {
        Canvas { context, size in
            let zoom = model.zoom
            let rect = CGRect(x: crop.minX * zoom, y: crop.minY * zoom, width: crop.width * zoom, height: crop.height * zoom)
            var scrim = Path(CGRect(origin: .zero, size: size))
            scrim.addRect(rect)
            context.fill(scrim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1)

            // Rule-of-thirds guides.
            var guides = Path()
            for i in 1 ... 2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                guides.move(to: CGPoint(x: x, y: rect.minY)); guides.addLine(to: CGPoint(x: x, y: rect.maxY))
                guides.move(to: CGPoint(x: rect.minX, y: y)); guides.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(guides, with: .color(.white.opacity(0.35)), lineWidth: 1)

            // Corner brackets.
            let arm: CGFloat = 16
            var corners = Path()
            for (_, point) in model.cropHandles(crop) {
                let p = CGPoint(x: point.x * zoom, y: point.y * zoom)
                let sx: CGFloat = p.x <= rect.midX ? 1 : -1
                let sy: CGFloat = p.y <= rect.midY ? 1 : -1
                corners.move(to: CGPoint(x: p.x, y: p.y + sy * arm))
                corners.addLine(to: p)
                corners.addLine(to: CGPoint(x: p.x + sx * arm, y: p.y))
            }
            context.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct InlineTextEditor: View {
    @Bindable var model: EditorModel
    let annotation: Annotation
    let content: CGRect
    @FocusState private var focused: Bool

    var body: some View {
        let zoom = model.zoom
        let frame = annotation.textFrame
        let pad = annotation.textPadding
        let filled = annotation.textStyle == .filled
        TextField("Type", text: model.binding(forText: annotation.id), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.custom(Jakarta.Weight.bold.postScriptName, fixedSize: annotation.fontSize * zoom))
            .foregroundStyle(filled ? (annotation.color.isLight ? Color(white: 0.1) : .white) : annotation.color.color)
            .focused($focused)
            .fixedSize()
            .padding(.horizontal, pad.width * zoom)
            .padding(.vertical, pad.height * zoom)
            .frame(minWidth: max(frame.width * zoom, 40), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: annotation.fontSize * 0.3 * zoom, style: .continuous)
                    .fill(filled ? annotation.color.color : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(-4)
            )
            .offset(x: (frame.minX - content.minX) * zoom, y: (frame.minY - content.minY) * zoom)
            .onAppear { focused = true }
            .onSubmit { model.commitTextEditing() }
            .onKeyPress(.escape) {
                model.commitTextEditing()
                return .handled
            }
    }
}

// MARK: - Options bar

private struct OptionsBar: View {
    @Bindable var model: EditorModel

    private var activeKind: Annotation.Kind? {
        model.selectedAnnotation?.kind ?? model.tool.annotationKind
    }

    private var showsColor: Bool {
        if let kind = model.selectedAnnotation?.kind { return kind != .redact && kind != .spotlight }
        return model.tool.usesColor
    }

    private var showsSize: Bool {
        if let kind = model.selectedAnnotation?.kind { return kind != .redact && kind != .spotlight }
        return model.tool.usesSize
    }

    var body: some View {
        Group {
            if model.tool == .crop {
                cropBar
            } else if showsColor || showsSize || activeKind == .redact || model.selection != nil {
                styleBar
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Radius.lg + 2, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg + 2, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadowLg()
        .opacity(model.tool == .select && model.selection == nil ? 0 : 1)
        .animation(Motion.quick, value: model.tool)
        .animation(Motion.quick, value: model.selection)
    }

    private var styleBar: some View {
        HStack(spacing: Space.md) {
            if showsColor {
                HStack(spacing: 6) {
                    ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { index, entry in
                        Swatch(color: entry.color, selected: entry.color == model.color) {
                            model.applyColor(entry.color)
                        }
                        .help("\(entry.name) (\(index + 1))")
                    }
                }
            }
            if showsSize {
                ShadSeparator(vertical: true).frame(height: 20)
                SizePicker(selection: model.sizeIndex) { model.applySize($0) }
            }
            if activeKind == .rectangle || activeKind == .ellipse {
                ShadSeparator(vertical: true).frame(height: 20)
                ShadTabs(selection: Binding(get: { model.shapeFilled }, set: { model.applyFilled($0) }), options: [(false, "Outline"), (true, "Filled")])
            }
            if activeKind == .text {
                ShadSeparator(vertical: true).frame(height: 20)
                ShadTabs(selection: Binding(get: { model.textStyle }, set: { model.applyTextStyle($0) }), options: TextStyleKind.allCases.map { ($0, $0.label) })
            }
            if activeKind == .redact {
                ShadTabs(selection: Binding(get: { model.redactStyle }, set: { model.applyRedactStyle($0) }), options: RedactStyle.allCases.map { ($0, $0.label) })
            }
            if model.selection != nil {
                ShadSeparator(vertical: true).frame(height: 20)
                IconButton(symbol: "trash", help: "Delete (⌫)", size: .iconSm) { model.deleteSelection() }
            }
        }
    }

    private var cropBar: some View {
        HStack(spacing: Space.md) {
            if let crop = model.pendingCrop {
                Text("\(Int(crop.width)) × \(Int(crop.height))")
                    .font(.jakarta(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
                    .frame(minWidth: 90)
            }
            ShadSeparator(vertical: true).frame(height: 20)
            Button("Reset") { model.resetCrop() }
                .buttonStyle(.shad(.ghost, size: .sm))
            Button("Cancel") { model.cancelCrop() }
                .buttonStyle(.shad(.outline, size: .sm))
            Button("Apply") { model.applyCrop() }
                .buttonStyle(.shad(.primary, size: .sm))
        }
    }
}

private struct Swatch: View {
    let color: RGBA
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Theme.foreground : .clear, lineWidth: 1.5))
                .scaleEffect(hovering && !selected ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
    }
}

private struct SizePicker: View {
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3) { index in
                Button { onSelect(index) } label: {
                    Circle()
                        .fill(Theme.foreground)
                        .frame(width: CGFloat(4 + index * 3), height: CGFloat(4 + index * 3))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .fill(selection == index ? Theme.accent : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["Thin", "Medium", "Thick"][index])
            }
        }
    }
}

private struct ZoomControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", help: "Zoom out (⌘−)", size: .iconSm) { set(model.zoom / 1.25) }
            Button {
                model.fitsWindow = true
            } label: {
                Text(model.fitsWindow ? "Fit" : "\(Int((model.zoom * model.pointScale * 100).rounded()))%")
                    .font(.jakarta(12, .medium))
                    .monospacedDigit()
                    .frame(width: 48)
            }
            .buttonStyle(.shad(.ghost, size: .sm))
            .help("Fit to window (⌘0)")
            IconButton(symbol: "plus", help: "Zoom in (⌘+)", size: .iconSm) { set(model.zoom * 1.25) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadowMd()
    }

    private func set(_ value: CGFloat) {
        model.fitsWindow = false
        model.zoom = min(max(value, 0.05), 8)
    }
}

// MARK: - Background

enum BackgroundLayout {
    static func compositeSize(content: CGSize, settings: BackgroundSettings, pointScale: CGFloat) -> CGSize {
        let pad = settings.padding * pointScale
        var size = CGSize(width: content.width + pad * 2, height: content.height + pad * 2)
        if let ratio = settings.aspect.ratio {
            if size.width / size.height < ratio {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

struct BackgroundFrame<Content: View>: View {
    let settings: BackgroundSettings
    let contentSize: CGSize
    let pointScale: CGFloat
    /// Display points per image pixel (1 when exporting).
    let unit: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let composite = BackgroundLayout.compositeSize(content: contentSize, settings: settings, pointScale: pointScale)
        let preset = BackgroundPreset.all[min(settings.preset, BackgroundPreset.all.count - 1)]
        let radius = settings.cornerRadius * pointScale * unit
        let shadow = settings.shadow
        ZStack {
            preset.gradient
            content
                .frame(width: contentSize.width * unit, height: contentSize.height * unit)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.18 * shadow), radius: 4 * pointScale * unit * shadow, y: 2 * pointScale * unit * shadow)
                .shadow(color: .black.opacity(0.3 * shadow), radius: 28 * pointScale * unit * shadow, y: 14 * pointScale * unit * shadow)
        }
        .frame(width: composite.width * unit, height: composite.height * unit)
    }
}

private struct BackgroundPanel: View {
    @Bindable var model: EditorModel

    private var settings: Binding<BackgroundSettings> {
        Binding(get: { model.document.background }, set: { value in model.change(coalescing: "background") { $0.background = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background")
                            .textStyle(.bodyStrong)
                            .foregroundStyle(Theme.foreground)
                        Text("Frame the capture for sharing.")
                            .textStyle(.footnote)
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    Spacer()
                    Toggle("", isOn: settings.enabled).toggleStyle(.shad).labelsHidden()
                }

                ShadSeparator()

                Group {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        label("Fill")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 4), spacing: Space.sm) {
                            ForEach(BackgroundPreset.all) { preset in
                                Button {
                                    var value = settings.wrappedValue
                                    value.preset = preset.id
                                    value.enabled = true
                                    settings.wrappedValue = value
                                } label: {
                                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                        .fill(preset.gradient)
                                        .frame(height: 40)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                                .strokeBorder(settings.wrappedValue.preset == preset.id ? Theme.foreground : Theme.border, lineWidth: settings.wrappedValue.preset == preset.id ? 2 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(preset.name)
                            }
                        }
                    }

                    sliderRow("Padding", value: settings.padding, range: 0 ... 160, step: 4, unit: "pt")
                    sliderRow("Corner radius", value: settings.cornerRadius, range: 0 ... 40, step: 1, unit: "pt")
                    sliderRow("Shadow", value: settings.shadow, range: 0 ... 1, step: 0.05, unit: "%", factor: 100)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        label("Aspect ratio")
                        ShadTabs(selection: settings.aspect, options: BackgroundAspect.allCases.map { ($0, $0.label) }, fullWidth: true)
                    }
                }
                .disabled(!model.document.background.enabled)
                .opacity(model.document.background.enabled ? 1 : 0.5)
            }
            .padding(Space.lg)
        }
        .frame(width: 272)
        .background(Theme.background)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .textStyle(.label)
            .foregroundStyle(Theme.foreground)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String, factor: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                label(title)
                Spacer()
                Text("\(Int((value.wrappedValue * factor).rounded()))\(unit == "%" ? "%" : "")")
                    .font(.jakarta(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
            }
            ShadSlider(value: value, range: range, step: step)
        }
    }
}
