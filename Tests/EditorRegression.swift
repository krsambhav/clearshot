import AppKit
import SwiftUI

@main
struct EditorRegression {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let image = context.makeImage()!
        let record = CaptureRecord(id: UUID(), date: Date(), kind: .screenshot, pixelWidth: 320,
                                   pixelHeight: 180, scale: 2, baseName: "Editor regression")
        let model = EditorModel(record: record, image: image, document: nil)
        var copies = 0, saves = 0
        let actions = EditorActions(copy: { copies += 1 }, save: { saves += 1 }, dragFile: { nil })
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            passed += 1
            print("PASS \(message)")
        }
        func key(_ text: String, modifiers: NSEvent.ModifierFlags = [], editing: Bool = false) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
            return EditorKeyboard.handle(event, model: model, actions: actions, isEditingText: editing)
        }
        for tool in EditorTool.allCases {
            check(key(String(tool.key)) && model.tool == tool, "Shortcut selects \(tool.title)")
        }
        check(!key("b", editing: true), "Typing B in text stays text")
        check(!key("b", modifiers: .option), "Option shortcuts are not intercepted")
        check(!key("c", modifiers: .command, editing: true) && copies == 0, "Text copy stays native")
        check(key("c", modifiers: .command) && copies == 1, "Image copy invokes action")
        check(key("s", modifiers: .command, editing: true) && saves == 1, "Save works while editing text")
        let annotation = Annotation(kind: .rectangle, start: CGPoint(x: 30, y: 30), end: CGPoint(x: 100, y: 100), color: RGBA.palette[0].color, size: 5)
        model.change { $0.annotations.append(annotation) }
        model.selection = annotation.id
        _ = key("b")
        check(model.selection == nil && model.tool == .redact, "B clears stale shape selection")
        _ = key("z", modifiers: .command)
        check(model.document.annotations.isEmpty, "Command Z undoes annotation")
        _ = key("z", modifiers: [.command, .shift])
        check(model.document.annotations.count == 1, "Command Shift Z redoes annotation")
        let snapshot = model.exportSnapshot()
        model.change { $0.annotations.removeAll() }
        model.markSaved(document: snapshot.document)
        check(model.hasChanges && snapshot.document.annotations.count == 1, "Export preserves its revision and leaves later edits dirty")
        guard let rendered = await EditorRenderer.render(snapshot) else { fatalError("Rendering failed") }
        check(rendered.width == 320 && rendered.height == 180, "Export retains original pixel size")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("saved.png")
        try ImageCodec.encode(rendered, as: .png)!.write(to: file)
        check(ImageCodec.load(file)?.width == 320, "Exported PNG is readable")
        snapshot.document.crop = CGRect(x: 10, y: 10, width: 100, height: 80)
        check(EditorRenderer.renderSync(snapshot)?.width == 100, "Crop is applied to exported image")
        snapshot.document.background.enabled = true
        check((EditorRenderer.renderSync(snapshot)?.width ?? 0) > 100, "Background is included in export")
        var swipe = ThumbnailSwipeState()
        check(!swipe.consume(x: 20, y: 0, inverted: false, phase: .began), "Small horizontal scroll does not dismiss")
        check(swipe.consume(x: 35, y: 1, inverted: false, phase: .changed), "Left swipe dismisses")
        check(!swipe.consume(x: 80, y: 0, inverted: false, phase: .changed), "One dismissal per gesture")
        check(!swipe.consume(x: 80, y: 0, inverted: false, phase: .changed, momentum: .changed), "Momentum cannot dismiss another thumbnail")
        check(swipe.consume(x: -60, y: 0, inverted: true, phase: .began), "Left swipe works with Natural Scrolling")
        check(!swipe.consume(x: -80, y: 0, inverted: false, phase: .began), "Right swipe does not dismiss")
        check(!swipe.consume(x: 60, y: 90, inverted: false, phase: .began), "Vertical scroll does not dismiss")
        check(!swipe.consume(x: 80, y: 0, inverted: false, phase: .cancelled), "Cancelled swipe does not dismiss")
        print("RESULT: \(passed) checks passed")
    }
}
