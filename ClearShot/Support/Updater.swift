import AppKit

/// Checks GitHub Releases for a newer build and installs it in place, then relaunches.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String, url: URL)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    private let latestRelease = URL(string: "https://api.github.com/repos/krsambhav/clearshot/releases/latest")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: latestRelease, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard let asset = release.assets.first(where: { $0.name == "ClearShot.zip" }) else {
                state = .failed("The latest release has no download.")
                return
            }
            state = Self.isNewer(latest, than: currentVersion)
                ? .available(version: latest, url: asset.browserDownloadURL)
                : .upToDate
        } catch {
            state = .failed("Couldn't reach GitHub.")
        }
    }

    func install(from url: URL) async {
        state = .installing
        do {
            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError("No permission to replace \(target.path).")
            }

            let (download, _) = try await URLSession.shared.download(from: url)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClearShot-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("ClearShot.zip")
            try FileManager.default.moveItem(at: download, to: zip)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            let app = work.appendingPathComponent("ClearShot.app")
            guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download isn't a valid ClearShot build.")
            }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", app.path])

            // Swap the bundle once this process exits, then relaunch.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1" && ditto "$2" "$1" && xattr -dr com.apple.quarantine "$1" 2>/dev/null
            open "$1"
            rm -rf "$3"
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/bash")
            swap.arguments = ["-c", script, "swap", target.path, app.path, work.path]
            try swap.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "Update failed: \(error.localizedDescription)")
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() } else {
                    continuation.resume(throwing: UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
