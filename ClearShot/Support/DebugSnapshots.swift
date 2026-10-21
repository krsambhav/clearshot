#if DEBUG
import AppKit
import SwiftUI

/// Renders key screens offscreen to PNG for visual review.
/// Run with CLEARSHOT_SNAPSHOTS=/path/to/folder; the app quits when done.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CLEARSHOT_SNAPSHOTS"] else { return false }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task {
            await run(into: folder)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func run(into folder: URL) async {
        let sample = sampleImage()
        let seeded = seedHistory(sample)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"

            for section in [SettingsSection.capture, .shortcuts, .about] {
                let model = SettingsModel()
                model.section = section
                await snap(SettingsView(model: model), size: CGSize(width: 760, height: 560), appearance: appearance, to: folder.appendingPathComponent("settings-\(section.rawValue)-\(suffix).png"))
            }

            for step in OnboardingModel.Step.allCases {
                let model = OnboardingModel()
                model.step = step
                await snap(OnboardingView(model: model) {}, size: CGSize(width: 600, height: 520), appearance: appearance, to: folder.appendingPathComponent("onboarding-\(step.rawValue)-\(suffix).png"))
            }

            await snap(StatusMenu(close: {}), size: CGSize(width: 324, height: 520), appearance: appearance, to: folder.appendingPathComponent("menu-\(suffix).png"))

            await snap(HistoryView(), size: CGSize(width: 980, height: 660), appearance: appearance, to: folder.appendingPathComponent("history-\(suffix).png"))

            if let record = seeded.first {
                let model = EditorModel(record: record, image: sample, document: sampleDocument(scale: 2))
                model.selection = model.document.annotations.first?.id
                await model.loadEffects()
                await snap(EditorView(model: model, actions: EditorActions(copy: {}, save: {}, dragFile: { nil })), size: CGSize(width: 1200, height: 800), appearance: appearance, to: folder.appendingPathComponent("editor-\(suffix).png"))

                let framed = EditorModel(record: record, image: sample, document: {
                    var doc = sampleDocument(scale: 2)
                    doc.background.enabled = true
                    return doc
                }())
                framed.showsBackgroundPanel = true
                framed.tool = .select
                await framed.loadEffects()
                await snap(EditorView(model: framed, actions: EditorActions(copy: {}, save: {}, dragFile: { nil })), size: CGSize(width: 1200, height: 800), appearance: appearance, to: folder.appendingPathComponent("editor-background-\(suffix).png"))

                if let output = EditorRenderer.renderSync(framed), let data = ImageCodec.encode(output, as: .png) {
                    try? data.write(to: folder.appendingPathComponent("export-\(suffix).png"))
                }
            }
        }

        for record in seeded { HistoryStore.shared.delete(record.id) }
        HistoryStore.shared.saveNow()
    }

    private static func snap<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = Theme.nsBackground
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    private static func seedHistory(_ image: CGImage) -> [CaptureRecord] {
        var records: [CaptureRecord] = []
        records.append(HistoryStore.shared.add(image: image, scale: 2, kind: .screenshot))
        var text = HistoryStore.shared.add(image: image, scale: 2, kind: .text, text: "Deploy failed: connection reset by peer (ECONNRESET) while uploading build artifacts")
        text.text = "Deploy failed: connection reset by peer (ECONNRESET) while uploading build artifacts"
        HistoryStore.shared.update(text)
        records.append(text)
        records.append(HistoryStore.shared.add(image: image, scale: 2, kind: .screenshot))
        return records
    }

    private static func sampleDocument(scale: CGFloat) -> EditorDocument {
        var doc = EditorDocument()
        let red = RGBA.palette[0].color
        doc.annotations = [
            Annotation(kind: .arrow, start: CGPoint(x: 1180, y: 640), end: CGPoint(x: 860, y: 420), color: red, size: 5 * scale),
            Annotation(kind: .rectangle, start: CGPoint(x: 120, y: 330), end: CGPoint(x: 800, y: 520), color: red, size: 5 * scale),
            {
                var a = Annotation(kind: .text, start: CGPoint(x: 1000, y: 680), end: .zero, color: red, size: 5 * scale)
                a.text = "This is the bug"
                a.textStyle = .filled
                return a
            }(),
            { var a = Annotation(kind: .counter, start: CGPoint(x: 120, y: 330), end: .zero, color: RGBA.palette[4].color, size: 5 * scale); a.number = 1; return a }(),
            { var a = Annotation(kind: .counter, start: CGPoint(x: 120, y: 640), end: .zero, color: RGBA.palette[4].color, size: 5 * scale); a.number = 2; return a }(),
            Annotation(kind: .redact, start: CGPoint(x: 1200, y: 50), end: CGPoint(x: 1625, y: 108), color: red, size: 5 * scale),
            Annotation(kind: .marker, start: .zero, end: .zero, points: [CGPoint(x: 140, y: 820), CGPoint(x: 500, y: 822), CGPoint(x: 760, y: 820)], color: RGBA.palette[2].color, size: 5 * scale),
        ]
        return doc
    }

    /// A fake app window so screens have realistic content.
    private static func sampleImage() -> CGImage {
        let size = CGSize(width: 1680, height: 1000)
        let view = VStack(alignment: .leading, spacing: 24) {
            HStack {
                Circle().fill(.red).frame(width: 22, height: 22)
                Circle().fill(.yellow).frame(width: 22, height: 22)
                Circle().fill(.green).frame(width: 22, height: 22)
                Spacer()
                Text("api-key: sk-live-4f9a…").font(.system(size: 30, design: .monospaced))
            }
            Text("Deployments").font(.system(size: 64, weight: .bold))
            VStack(alignment: .leading, spacing: 18) {
                ForEach(["web — Ready — 2m ago", "api — Failed — 5m ago", "worker — Ready — 1h ago"], id: \.self) { row in
                    Text(row).font(.system(size: 40))
                        .padding(28)
                        .frame(maxWidth: 900, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.94)))
                }
            }
            Text("Deploy failed: connection reset by peer (ECONNRESET)").font(.system(size: 40, weight: .medium)).foregroundStyle(.red)
            Spacer()
        }
        .padding(60)
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .foregroundStyle(Color(white: 0.12))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage!
    }
}
#endif
