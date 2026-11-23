import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

@MainActor
@Observable
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    private enum Phase { case idle, starting, recording, paused, stopping }
    private var phase = Phase.idle
    private(set) var lastRecording: URL?
    var isBusy: Bool { phase != .idle }
    var isPaused: Bool { phase == .paused }
    var canControl: Bool { phase == .recording || phase == .paused }
    var controlTitle: String {
        switch phase {
        case .idle, .starting: "Starting…"
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopping: "Finishing…"
        }
    }
    var menuTitle: String {
        switch phase {
        case .idle: "Record Screen"
        case .starting, .recording, .paused: "Stop Recording"
        case .stopping: "Saving Recording…"
        }
    }

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var onStopped: (() -> Void)?
    @ObservationIgnored private var controls: RecordingControlsPanel?

    func start(on screen: NSScreen, region: CGRect?, in folder: URL) {
        guard phase == .idle else { return }
        guard let displayID = screen.displayID else {
            ToastCenter.shared.show(.error, "Couldn't start recording", detail: CaptureError.noDisplay.localizedDescription)
            return
        }
        let id = UUID()
        activeID = id
        phase = .starting
        StatusBarController.shared?.indicateRecording(true)
        let controls = RecordingControlsPanel(screen: screen, recorder: self)
        self.controls = controls
        controls.orderFrontRegardless()
        let controlsID = CGWindowID(controls.windowNumber)

        let displayRate = screen.maximumFramesPerSecond
        let frameRate = min(displayRate > 0 ? displayRate : 60, Preferences.shared.recordingFrameRate.rawValue)
        let stamp = Date()
        Task { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if stopRequested {
                    reset()
                    return
                }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw CaptureError.noDisplay
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let draft = folder.appendingPathComponent(".clearshot-\(UUID()).mp4")

                let filter: SCContentFilter
                if let panel = content.windows.first(where: { $0.windowID == controlsID }) {
                    filter = SCContentFilter(display: display, excludingWindows: [panel])
                } else if let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
                    // A newly ordered panel may not be listed yet. Keep it excluded by its owning app.
                    filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
                } else {
                    throw RecordingError.controlsNotExcludable
                }
                let config = Self.configuration(for: filter, region: region, highRefreshDisplay: displayRate > 60)
                let writer = try RecordingWriter(url: draft, configuration: config, frameRate: frameRate,
                                                 limitFrameRate: displayRate > frameRate || displayRate <= 0) { [weak self] error in
                    Task { @MainActor in self?.interrupted(id: id, error: error, streamStopped: false) }
                }
                let delegate = StreamDelegate { [weak self] error in
                    Task { @MainActor in self?.interrupted(id: id, error: error, streamStopped: true) }
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                let recording = Session(stream: stream, delegate: delegate, writer: writer, draft: draft, date: stamp)
                session = recording
                try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
                try await stream.startCapture()
                guard phase == .starting, activeID == id else { return }
                phase = .recording
                if stopRequested { stop() }
            } catch {
                guard phase == .starting, activeID == id else { return }
                phase = .stopping
                if let session {
                    await session.writer.cancel()
                    try? FileManager.default.removeItem(at: session.draft)
                }
                ToastCenter.shared.show(.error, "Couldn't start recording", detail: error.localizedDescription)
                reset()
            }
        }
    }

    func stop(onStopped: (() -> Void)? = nil) {
        if let onStopped { self.onStopped = onStopped }
        if phase == .starting {
            stopRequested = true
        } else if canControl, let session {
            finish(session)
        }
    }

    func togglePause() {
        guard canControl, let session else { return }
        let resume = isPaused
        session.writer.setPaused(!resume, at: Self.currentTime(for: session.stream))
        phase = resume ? .recording : .paused
    }

    func discard() {
        guard canControl, let session else { return }
        phase = .stopping
        controls?.orderOut(nil)
        Task {
            try? await session.stream.stopCapture()
            await session.writer.cancel()
            do {
                try FileManager.default.removeItem(at: session.draft)
                ToastCenter.shared.show(.info, "Recording deleted")
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                ToastCenter.shared.show(.info, "Recording deleted")
            } catch {
                ToastCenter.shared.show(.error, "Couldn't delete recording", detail: error.localizedDescription)
            }
            reset()
        }
    }

    func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if lastRecording == url { lastRecording = nil }
            ToastCenter.shared.show(.warning, "Recording file has moved", detail: url.abbreviatedPath)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func interrupted(id: UUID, error: Error, streamStopped: Bool) {
        guard let session, activeID == id, phase == .starting || canControl else { return }
        finish(session, interruption: error, streamStopped: streamStopped)
    }

    private func finish(_ session: Session, interruption: Error? = nil, streamStopped: Bool = false) {
        phase = .stopping
        let end = Self.currentTime(for: session.stream)
        Task {
            if !streamStopped { try? await session.stream.stopCapture() }
            do {
                try await session.writer.finish(at: end)
                let url = FileNaming.uniqueURL(in: session.draft.deletingLastPathComponent(),
                                               baseName: "\(FileNaming.baseName(for: session.date)) Recording", ext: "mp4")
                do {
                    try FileManager.default.moveItem(at: session.draft, to: url)
                    lastRecording = url
                    let title = interruption == nil ? "Recording saved" : "Recording ended and was saved"
                    ToastCenter.shared.show(.success, title, detail: url.abbreviatedPath)
                } catch {
                    lastRecording = session.draft
                    ToastCenter.shared.show(.warning, "Recording saved under a temporary name", detail: error.localizedDescription)
                }
            } catch {
                try? FileManager.default.removeItem(at: session.draft)
                ToastCenter.shared.show(.error, "Couldn't save recording", detail: (interruption ?? error).localizedDescription)
            }
            reset()
        }
    }

    private func reset() {
        controls?.orderOut(nil)
        controls = nil
        session = nil
        activeID = nil
        phase = .idle
        stopRequested = false
        StatusBarController.shared?.indicateRecording(false)
        let completion = onStopped
        onStopped = nil
        completion?()
    }

    private static func currentTime(for stream: SCStream) -> CMTime {
        CMClockGetTime(stream.synchronizationClock ?? CMClockGetHostTimeClock())
    }

    private static func configuration(for filter: SCContentFilter, region: CGRect?, highRefreshDisplay: Bool) -> SCStreamConfiguration {
        let size = region?.size ?? filter.contentRect.size
        let pixelWidth = size.width * CGFloat(filter.pointPixelScale)
        let pixelHeight = size.height * CGFloat(filter.pointPixelScale)
        // Bound WindowServer's capture work even on high-resolution Retina displays.
        let scale = min(1, 1920 / max(pixelWidth, pixelHeight), 1200 / min(pixelWidth, pixelHeight))

        let config = SCStreamConfiguration()
        if let region { config.sourceRect = region }
        config.width = max(2, Int(pixelWidth * scale) / 2 * 2)
        config.height = max(2, Int(pixelHeight * scale) / 2 * 2)
        // Let ScreenCaptureKit follow the display. Apply the video's frame rate in the writer.
        config.minimumFrameInterval = .zero
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.itur_709
        config.showsCursor = true
        config.queueDepth = highRefreshDisplay ? 6 : 4
        return config
    }

    private struct Session {
        let stream: SCStream
        let delegate: StreamDelegate
        let writer: RecordingWriter
        let draft: URL
        let date: Date
    }
}

private nonisolated final class StreamDelegate: NSObject, SCStreamDelegate {
    let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

private nonisolated enum RecordingError: LocalizedError {
    case encoderUnavailable, noFrames, encodingFailed, controlsNotExcludable

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable: "A video encoder is unavailable for this display."
        case .noFrames: "The display didn’t deliver any video frames."
        case .encodingFailed: "The video encoder couldn’t complete the recording."
        case .controlsNotExcludable: "ClearShot couldn’t hide the recording controls from the video."
        }
    }
}

/// Serializes frame admission and finalization on the same queue.
private nonisolated final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.clearshot.recording.video", qos: .userInitiated)
    private let asset: AVAssetWriter
    private let input: AVAssetWriterInput
    private let onFailure: @Sendable (Error) -> Void
    private let frameInterval: CMTime
    private let limitFrameRate: Bool
    private let frameTimingTolerance = CMTime(value: 1, timescale: 1000)
    private var nextFrameTime = CMTime.invalid
    private var lastFrame: CMSampleBuffer?
    private var acceptingFrames = true
    private var pauseStart: CMTime?
    private var resumedAt: CMTime?
    private var pausedDuration = CMTime.zero

    init(url: URL, configuration: SCStreamConfiguration, frameRate: Int, limitFrameRate: Bool,
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        asset = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, configuration.width * configuration.height * frameRate / 20),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        guard asset.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RecordingError.encoderUnavailable
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard asset.canAdd(input) else { throw RecordingError.encoderUnavailable }
        asset.add(input)
        asset.movieTimeScale = 60000
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        self.limitFrameRate = limitFrameRate
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptingFrames, pauseStart == nil, type == .screen, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil else { return }
        let sourceTime = sampleBuffer.presentationTimeStamp
        guard sourceTime.isNumeric, sourceTime >= (resumedAt ?? .negativeInfinity) else { return }
        let timestamp = sourceTime - pausedDuration
        guard timestamp > (lastFrame?.presentationTimeStamp ?? .negativeInfinity) else { return }
        if nextFrameTime.isValid, timestamp + frameTimingTolerance < nextFrameTime { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), status == .complete || status == .started else { return }
        if asset.status == .unknown {
            guard asset.startWriting() else { fail(); return }
            asset.startSession(atSourceTime: timestamp)
        }
        guard asset.status == .writing else { fail(); return }
        // Drop frames under encoder backpressure and retain only the most recent accepted frame.
        guard input.isReadyForMoreMediaData else { return }
        var frame = sampleBuffer
        if pausedDuration > .zero {
            guard let shifted = Self.retime(sampleBuffer, to: timestamp, duration: sampleBuffer.duration) else {
                fail()
                return
            }
            frame = shifted
        }
        guard input.append(frame) else { fail(); return }
        lastFrame = frame
        if limitFrameRate {
            // Follow the output cadence through small timestamp jitter and skip missed slots.
            let earliest = timestamp - frameTimingTolerance
            nextFrameTime = (nextFrameTime.isValid ? max(nextFrameTime, earliest) : timestamp) + frameInterval
        }
    }

    func setPaused(_ paused: Bool, at time: CMTime) {
        queue.async {
            if paused {
                self.pauseStart = time
            } else if let start = self.pauseStart {
                self.pausedDuration = self.pausedDuration + max(.zero, time - start)
                self.resumedAt = time
                self.pauseStart = nil
            }
        }
    }

    func finish(at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.acceptingFrames = false
                let lastFrame = self.lastFrame
                self.lastFrame = nil
                guard self.asset.status == .writing, let lastFrame else {
                    let error = self.asset.error ?? RecordingError.noFrames
                    if self.asset.status == .writing { self.asset.cancelWriting() }
                    continuation.resume(throwing: error)
                    return
                }
                let end = max((self.pauseStart ?? time) - self.pausedDuration, lastFrame.presentationTimeStamp + self.frameInterval)
                self.extend(lastFrame, to: end)
                self.asset.endSession(atSourceTime: end)
                self.input.markAsFinished()
                self.asset.finishWriting {
                    if self.asset.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: self.asset.error ?? RecordingError.encodingFailed)
                    }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.acceptingFrames = false
                self.lastFrame = nil
                if self.asset.status == .writing { self.asset.cancelWriting() }
                continuation.resume()
            }
        }
    }

    private func extend(_ lastFrame: CMSampleBuffer, to end: CMTime) {
        // ScreenCaptureKit skips unchanged frames. Repeat the last image at the end of a static tail.
        let timestamp = end - frameInterval
        guard timestamp > lastFrame.presentationTimeStamp, input.isReadyForMoreMediaData else { return }
        if let finalFrame = Self.retime(lastFrame, to: timestamp, duration: frameInterval) { _ = input.append(finalFrame) }
    }

    private static func retime(_ frame: CMSampleBuffer, to timestamp: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame, sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    private func fail() {
        acceptingFrames = false
        onFailure(asset.error ?? RecordingError.encodingFailed)
    }
}
