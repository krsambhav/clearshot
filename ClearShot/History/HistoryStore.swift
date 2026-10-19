import AppKit
import Foundation

nonisolated struct CaptureRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case screenshot, text
    }

    let id: UUID
    let date: Date
    var kind: Kind
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double
    /// Recognized text: the copied result for text captures, a search index for screenshots.
    var text: String?
    /// Where the image was exported in the user's folder, if it was.
    var exportedPath: String?
    var isAnnotated = false
    var baseName: String

    var pointSize: CGSize { CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale) }
}

/// Every capture lives in its own folder under Application Support:
///   <id>/<baseName>.png   current image (annotated, if edited)
///   <id>/original.png      untouched capture, kept once the image is edited
///   <id>/annotations.json  editable annotation document
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var records: [CaptureRecord] = []

    @ObservationIgnored let root: URL
    @ObservationIgnored private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnails = NSCache<NSUUID, NSImage>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("ClearShot/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: Paths

    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func imageURL(for record: CaptureRecord) -> URL { folder(for: record.id).appendingPathComponent(record.baseName).appendingPathExtension("png") }
    func originalURL(for record: CaptureRecord) -> URL { folder(for: record.id).appendingPathComponent("original.png") }
    func documentURL(for record: CaptureRecord) -> URL { folder(for: record.id).appendingPathComponent("annotations.json") }

    func record(_ id: UUID) -> CaptureRecord? { records.first { $0.id == id } }

    // MARK: Mutations

    /// Adds a capture immediately; the PNG is encoded off the main actor.
    @discardableResult
    func add(image: CGImage, scale: CGFloat, kind: CaptureRecord.Kind, text: String? = nil) -> CaptureRecord {
        let date = Date()
        let record = CaptureRecord(
            id: UUID(), date: date, kind: kind,
            pixelWidth: image.width, pixelHeight: image.height, scale: scale,
            text: text, baseName: FileNaming.baseName(for: date)
        )
        records.insert(record, at: 0)
        thumbnails.setObject(NSImage(cgImage: ImageCodec.thumbnail(image, maxPixelSize: 640) ?? image, scale: 1), forKey: record.id as NSUUID)

        let folder = folder(for: record.id)
        let url = imageURL(for: record)
        pendingWrites[record.id] = Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = ImageCodec.encode(image, as: .png, dpiScale: scale) {
                try? data.write(to: url, options: .atomic)
            }
        }
        scheduleSave()
        return record
    }

    func update(_ record: CaptureRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        scheduleSave()
    }

    /// Replaces the current image (e.g. after annotating), keeping the original once.
    func replaceImage(of id: UUID, with image: CGImage, pngData: Data) throws {
        guard var record = record(id) else { throw CocoaError(.fileNoSuchFile) }
        let original = originalURL(for: record)
        let current = imageURL(for: record)
        if !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: current, to: original)
        }
        try pngData.write(to: current, options: .atomic)
        record.isAnnotated = true
        record.pixelWidth = image.width
        record.pixelHeight = image.height
        thumbnails.setObject(NSImage(cgImage: ImageCodec.thumbnail(image, maxPixelSize: 640) ?? image, scale: 1), forKey: id as NSUUID)
        update(record)
    }

    func delete(_ id: UUID) {
        pendingWrites[id]?.cancel()
        records.removeAll { $0.id == id }
        thumbnails.removeObject(forKey: id as NSUUID)
        try? FileManager.default.removeItem(at: folder(for: id))
        scheduleSave()
    }

    func deleteAll() {
        for record in records { try? FileManager.default.removeItem(at: folder(for: record.id)) }
        records.removeAll()
        thumbnails.removeAllObjects()
        scheduleSave()
    }

    func prune() {
        let days = Preferences.shared.historyRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for record in records where record.date < cutoff { delete(record.id) }
    }

    // MARK: Files

    /// Waits until the capture's PNG is on disk.
    func fileReady(_ id: UUID) async {
        await pendingWrites[id]?.value
        pendingWrites[id] = nil
    }

    func image(for record: CaptureRecord) async -> CGImage? {
        await fileReady(record.id)
        let url = imageURL(for: record)
        return await Task.detached { ImageCodec.load(url) }.value
    }

    func thumbnail(for record: CaptureRecord) async -> NSImage? {
        if let cached = thumbnails.object(forKey: record.id as NSUUID) { return cached }
        await fileReady(record.id)
        let url = imageURL(for: record)
        guard let cg = await Task.detached(operation: { ImageCodec.thumbnail(url, maxPixelSize: 640) }).value else { return nil }
        let image = NSImage(cgImage: cg, scale: 1)
        thumbnails.setObject(image, forKey: record.id as NSUUID)
        return image
    }

    func cachedThumbnail(_ id: UUID) -> NSImage? { thumbnails.object(forKey: id as NSUUID) }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([CaptureRecord].self, from: data))?
            .filter { FileManager.default.fileExists(atPath: folder(for: $0.id).path) } ?? []
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
