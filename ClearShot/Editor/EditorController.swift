import AppKit
import SwiftUI

/// Opens one annotation window per capture and writes results back to history non-destructively.
@MainActor
final class EditorController {
    static let shared = EditorController()

    private var windows: [UUID: NSWindow] = [:]
    private var models: [UUID: EditorModel] = [:]
    private var delegates: [UUID: EditorWindowDelegate] = [:]

    func open(_ record: CaptureRecord) {
        if let window = windows[record.id] {
            WindowFactory.present(window)
            return
        }
        Task {
            let history = HistoryStore.shared
            await history.fileReady(record.id)
            let originalURL = history.originalURL(for: record)
            let currentURL = history.imageURL(for: record)
            let documentURL = history.documentURL(for: record)
            let loaded: (CGImage?, EditorDocument?) = await Task.detached {
                let url = FileManager.default.fileExists(atPath: originalURL.path) ? originalURL : currentURL
                let document = (try? Data(contentsOf: documentURL)).flatMap { try? JSONDecoder().decode(EditorDocument.self, from: $0) }
                return (ImageCodec.load(url), document)
            }.value
            guard let image = loaded.0 else {
                ToastCenter.shared.show(.error, "Couldn't open capture", detail: "The image file is missing.")
                return
            }
            present(record: record, image: image, document: loaded.1)
        }
    }

    private func present(record: CaptureRecord, image: CGImage, document: EditorDocument?) {
        let model = EditorModel(record: record, image: image, document: document)
        let id = record.id
        let actions = EditorActions(
            copy: { [weak self] in self?.copy(id) },
            save: { [weak self] in self?.save(id) },
            dragFile: { [weak self] in self?.dragFile(id) }
        )

        let screen = NSScreen.withMouse?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let points = record.pointSize
        let size = CGSize(
            width: min(max(points.width + 220, 960), screen.width * 0.9),
            height: min(max(points.height + 240, 640), screen.height * 0.9)
        )
        let window = WindowFactory.make(title: record.baseName, size: size, minSize: CGSize(width: 900, height: 560)) {
            EditorView(model: model, actions: actions)
        }
        window.backgroundColor = Theme.nsBackground
        let delegate = EditorWindowDelegate { [weak self] in self?.windowWillClose(id) }
        window.delegate = delegate

        windows[id] = window
        models[id] = model
        delegates[id] = delegate
        WindowFactory.present(window)
    }

    private func windowWillClose(_ id: UUID) {
        if let model = models[id], model.hasChanges {
            model.commitTextEditing()
            Task { await self.persist(model) }
        }
        windows[id] = nil
        models[id] = nil
        delegates[id] = nil
    }

    // MARK: Actions

    private func copy(_ id: UUID) {
        guard let model = models[id] else { return }
        model.commitTextEditing()
        Task {
            guard let image = await EditorRenderer.render(model) else { return }
            Clipboard.copy(image: image, scale: model.pointScale)
            ToastCenter.shared.show(.success, "Copied to clipboard")
            await persist(model, rendered: image)
        }
    }

    private func save(_ id: UUID) {
        guard let model = models[id] else { return }
        model.commitTextEditing()
        Task {
            guard let image = await EditorRenderer.render(model) else { return }
            await persist(model, rendered: image)
            if let record = HistoryStore.shared.record(id) {
                await AppController.shared.export(record, image: image)
            }
        }
    }

    private func dragFile(_ id: UUID) -> URL? {
        guard let model = models[id], let image = EditorRenderer.renderSync(model),
              let data = ImageCodec.encode(image, as: .png, dpiScale: model.pointScale) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClearShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(model.record.baseName).appendingPathExtension("png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Writes the rendered image and the editable document back into history.
    private func persist(_ model: EditorModel, rendered: CGImage? = nil) async {
        let history = HistoryStore.shared
        guard let record = history.record(model.record.id) else { return }
        let document = model.document
        let documentURL = history.documentURL(for: record)

        if document == EditorDocument() {
            // Everything was removed: restore the untouched capture.
            let original = history.originalURL(for: record)
            if FileManager.default.fileExists(atPath: original.path),
               let data = try? Data(contentsOf: original) {
                history.replaceImage(of: record.id, with: model.image, pngData: data)
                var restored = history.record(record.id) ?? record
                restored.isAnnotated = false
                history.update(restored)
            }
            try? FileManager.default.removeItem(at: documentURL)
            model.markSaved()
            return
        }

        var output = rendered
        if output == nil { output = await EditorRenderer.render(model) }
        guard let output else { return }
        let scale = model.pointScale
        let encoded: (Data?, Data?) = await Task.detached {
            (ImageCodec.encode(output, as: .png, dpiScale: scale), try? JSONEncoder().encode(document))
        }.value
        guard let png = encoded.0 else { return }
        history.replaceImage(of: record.id, with: output, pngData: png)
        if let json = encoded.1 { try? json.write(to: documentURL, options: .atomic) }
        model.markSaved()

        if let updated = history.record(record.id) {
            QuickAccessController.shared.refresh(updated, thumbnail: history.cachedThumbnail(updated.id))
        }
    }
}

private final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Export rendering

@MainActor
enum EditorRenderer {
    static func render(_ model: EditorModel) async -> CGImage? {
        if model.document.annotations.contains(where: { $0.kind == .redact }) {
            await model.loadEffects()
        }
        return renderSync(model)
    }

    /// Renders at exact pixel size: annotations first, then the optional background frame.
    static func renderSync(_ model: EditorModel) -> CGImage? {
        let document = model.document
        let full = CGRect(origin: .zero, size: model.imageSize)
        let content = document.crop ?? full

        let canvas = AnnotatedCanvas(
            image: model.image, document: document, effects: model.effects,
            content: content, zoom: 1, pointScale: model.pointScale, hidden: nil, drawBase: true
        )
        .frame(width: content.width, height: content.height)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let annotated = renderer.cgImage else { return nil }
        guard document.background.enabled else { return annotated }

        let framed = BackgroundFrame(settings: document.background, contentSize: content.size, pointScale: model.pointScale, unit: 1) {
            Image(decorative: annotated, scale: 1).resizable()
        }
        let backgroundRenderer = ImageRenderer(content: framed)
        backgroundRenderer.scale = 1
        return backgroundRenderer.cgImage
    }
}
