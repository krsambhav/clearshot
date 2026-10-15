import AppKit

enum CaptureMode {
    case area, window, fullscreen, text
}

/// Coordinates captures and routes results to the clipboard, disk, Quick Access and history.
@MainActor
final class AppController {
    static let shared = AppController()

    private let capturer = ScreenCapturer()
    private var overlay: CaptureOverlayController?
    private var isCapturing = false
    private let prefs = Preferences.shared
    private let history = HistoryStore.shared

    // MARK: Entry points

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: capture(.area)
        case .captureWindow: capture(.window)
        case .captureFullscreen: capture(.fullscreen)
        case .captureText: capture(.text)
        case .openHistory: HistoryWindowController.shared.show()
        }
    }

    func capture(_ mode: CaptureMode) {
        guard !isCapturing else { return }
        guard ScreenPermission.isGranted else {
            ScreenPermission.request()
            OnboardingWindowController.shared.show(startAtPermission: true)
            return
        }
        isCapturing = true
        StatusBarController.shared?.closeMenu()

        Task {
            do {
                let session = try await capturer.snapshot()
                if mode == .fullscreen {
                    let mouse = NSEvent.mouseLocation
                    let display = session.displays.first { $0.frame.contains(mouse) } ?? session.displays[0]
                    isCapturing = false
                    handleScreenshot(display.image, scale: display.scale)
                    return
                }
                presentOverlay(session: session, mode: mode)
            } catch {
                isCapturing = false
                report(error)
            }
        }
    }

    private func presentOverlay(session: CaptureSession, mode: CaptureMode) {
        let purpose: CapturePurpose = mode == .text ? .text : .screenshot
        let controller = CaptureOverlayController(session: session, purpose: purpose, startInWindowMode: mode == .window) { [weak self] outcome in
            self?.overlay = nil
            self?.isCapturing = false
            self?.handle(outcome, purpose: purpose)
        }
        overlay = controller
        controller.present()
    }

    private func handle(_ outcome: OverlayOutcome, purpose: CapturePurpose) {
        switch outcome {
        case .cancelled:
            return
        case let .region(snapshot, rect):
            guard let image = snapshot.image.cropping(to: rect) else { return }
            purpose == .text ? recognize(image, scale: snapshot.scale) : handleScreenshot(image, scale: snapshot.scale)
        case let .window(target, snapshot):
            if purpose == .text, let snapshot {
                // Read what's visible: crop the frozen frame instead of re-capturing.
                let local = target.frame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
                    .intersection(CGRect(origin: .zero, size: snapshot.frame.size))
                let rect = CGRect(
                    x: local.minX * snapshot.scale,
                    y: (snapshot.frame.height - local.maxY) * snapshot.scale,
                    width: local.width * snapshot.scale,
                    height: local.height * snapshot.scale
                ).integral
                if let image = snapshot.image.cropping(to: rect) { recognize(image, scale: snapshot.scale) }
                return
            }
            Task {
                do {
                    let (image, scale) = try await capturer.capture(window: target)
                    handleScreenshot(image, scale: scale)
                } catch {
                    report(error)
                }
            }
        }
    }

    // MARK: Screenshot pipeline

    private func handleScreenshot(_ image: CGImage, scale: CGFloat) {
        Sounds.playShutter()
        let record = history.add(image: image, scale: scale, kind: .screenshot)

        if prefs.showQuickAccess {
            QuickAccessController.shared.show(record: record, image: image)
        }

        Task {
            if prefs.copyToClipboard { await copy(record, image: image, announce: false) }
            if prefs.saveToFolder { await export(record, image: image, announce: false) }
            if !prefs.showQuickAccess { announceCapture() }
        }

        indexText(of: record, image: image)
    }

    private func announceCapture() {
        switch (prefs.copyToClipboard, prefs.saveToFolder) {
        case (true, true): ToastCenter.shared.show(.success, "Screenshot copied and saved")
        case (true, false): ToastCenter.shared.show(.success, "Screenshot copied")
        case (false, true): ToastCenter.shared.show(.success, "Screenshot saved", detail: prefs.exportFolder.abbreviatedPath)
        case (false, false): ToastCenter.shared.show(.success, "Screenshot added to history")
        }
    }

    /// Indexes screenshot text in the background so history is searchable.
    private func indexText(of record: CaptureRecord, image: CGImage) {
        let thumb = ImageCodec.thumbnail(image, maxPixelSize: 2400) ?? image
        Task(priority: .utility) {
            let options = RecognitionOptions(accurate: false, keepLineBreaks: false, languageCorrection: false, detectCodes: false)
            guard let result = try? await TextRecognizer.recognize(thumb, options: options), !result.text.isEmpty,
                  var current = history.record(record.id) else { return }
            current.text = result.text
            history.update(current)
        }
    }

    // MARK: Text pipeline

    private func recognize(_ image: CGImage, scale: CGFloat) {
        let options = RecognitionOptions(
            accurate: true,
            keepLineBreaks: prefs.ocrKeepLineBreaks,
            languageCorrection: prefs.ocrLanguageCorrection,
            detectCodes: prefs.ocrDetectCodes
        )
        Task {
            do {
                let result = try await TextRecognizer.recognize(image, options: options)
                if !result.text.isEmpty {
                    Clipboard.copy(text: result.text)
                    Sounds.playCopied()
                    let words = result.wordCount
                    ToastCenter.shared.show(.success, "Copied \(words) \(words == 1 ? "word" : "words")", detail: result.text.singleLinePreview)
                } else if !result.codes.isEmpty {
                    let payload = result.codes.joined(separator: "\n")
                    Clipboard.copy(text: payload)
                    Sounds.playCopied()
                    ToastCenter.shared.show(.success, result.codes.count == 1 ? "Copied code contents" : "Copied \(result.codes.count) codes", detail: payload.singleLinePreview)
                } else {
                    ToastCenter.shared.show(.warning, "No text found", detail: "Try selecting a larger area around the text.")
                }
                if !result.isEmpty {
                    history.add(image: image, scale: scale, kind: .text, text: result.text.isEmpty ? result.codes.joined(separator: "\n") : result.text)
                }
            } catch {
                report(error)
            }
        }
    }

    // MARK: Actions on captures

    func copy(_ record: CaptureRecord, image: CGImage? = nil, announce: Bool = true) async {
        await history.fileReady(record.id)
        let url = history.imageURL(for: record)
        let png = await Task.detached { try? Data(contentsOf: url) }.value
        var source = image
        if source == nil { source = await history.image(for: record) }
        guard let source else { return }
        Clipboard.copy(image: source, pngData: png, scale: record.scale)
        if announce { ToastCenter.shared.show(.success, "Copied to clipboard") }
    }

    @discardableResult
    func export(_ record: CaptureRecord, image: CGImage? = nil, announce: Bool = true) async -> URL? {
        var source = image
        if source == nil || record.isAnnotated { source = await history.image(for: record) }
        guard let source else { return nil }

        let folder = prefs.exportFolder
        let format = prefs.imageFormat
        let scale = CGFloat(record.scale)
        let downscale = prefs.downscaleRetina && scale > 1
        let existing = record.exportedPath.map(URL.init(fileURLWithPath:))
        let url = existing.flatMap { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension == format.fileExtension ? $0 : nil }
            ?? FileNaming.uniqueURL(in: folder, baseName: record.baseName, ext: format.fileExtension)

        let written: Bool = await Task.detached {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var output = source
            if downscale, let small = ImageCodec.resized(source, to: CGSize(width: CGFloat(source.width) / scale, height: CGFloat(source.height) / scale)) {
                output = small
            }
            guard let data = ImageCodec.encode(output, as: format, dpiScale: downscale ? 1 : scale) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value

        guard written else {
            ToastCenter.shared.show(.error, "Couldn't save screenshot", detail: "Check that \(folder.abbreviatedPath) is writable.")
            return nil
        }
        if var current = history.record(record.id) {
            current.exportedPath = url.path
            history.update(current)
        }
        if announce { ToastCenter.shared.show(.success, "Saved", detail: url.abbreviatedPath) }
        return url
    }

    func pin(_ record: CaptureRecord) {
        Task {
            guard let image = await history.image(for: record) else { return }
            PinController.shared.pin(image: image, scale: CGFloat(record.scale), recordID: record.id)
        }
    }

    func annotate(_ record: CaptureRecord) {
        EditorController.shared.open(record)
    }

    /// Imports an image from disk into history and opens it for annotation.
    func openImageFile(_ url: URL) {
        Task {
            guard let image = await Task.detached(operation: { ImageCodec.load(url) }).value else {
                ToastCenter.shared.show(.error, "Couldn't open image", detail: url.lastPathComponent)
                return
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let record = history.add(image: image, scale: scale, kind: .screenshot)
            annotate(record)
        }
    }

    func revealInFinder(_ record: CaptureRecord) {
        if let path = record.exportedPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([history.imageURL(for: record)])
        }
    }

    private func report(_ error: Error) {
        if case CaptureError.permissionDenied = error {
            OnboardingWindowController.shared.show(startAtPermission: true)
            return
        }
        ToastCenter.shared.show(.error, "Capture failed", detail: error.localizedDescription)
    }
}

extension String {
    var singleLinePreview: String {
        let collapsed = split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count > 90 ? String(collapsed.prefix(90)) + "…" : collapsed
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
