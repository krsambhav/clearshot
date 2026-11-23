import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

@MainActor
@Observable
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    private enum Phase { case idle, starting, recording, stopping }
    private var phase = Phase.idle
    private(set) var lastRecording: URL?
    var isBusy: Bool { phase != .idle }
    var menuTitle: String {
        switch phase {
        case .idle: "Record Screen"
        case .starting, .recording: "Stop Recording"
        case .stopping: "Saving Recording…"
        }
    }

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var onStopped: (() -> Void)?

    func start(on screen: NSScreen, in folder: URL) {
        guard phase == .idle else { return }
        guard let displayID = screen.displayID else {
            ToastCenter.shared.show(.error, "Couldn't start recording", detail: CaptureError.noDisplay.localizedDescription)
            return
        }
        let id = UUID()
        activeID = id
        phase = .starting
        StatusBarController.shared?.indicateRecording(true)

        let displayRate = screen.maximumFramesPerSecond
        let frameRate = displayRate > 0 ? min(displayRate, 120) : 60
        let stamp = Date()
        Task { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if stopRequested {
                    reset()
                    return
                }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw CaptureError.noDisplay
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let draft = folder.appendingPathComponent(".clearshot-\(UUID()).mp4")

                // Limit pixel throughput at high refresh rates, while keeping the display's aspect ratio.
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = Self.configuration(for: filter, frameRate: frameRate, useNativeRate: displayRate == frameRate)
                let writer = try RecordingWriter(url: draft, configuration: config, frameRate: frameRate) { [weak self] error in
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
        } else if phase == .recording, let session {
            finish(session)
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
        guard let session, activeID == id, phase == .starting || phase == .recording else { return }
        finish(session, interruption: error, streamStopped: streamStopped)
    }

    private func finish(_ session: Session, interruption: Error? = nil, streamStopped: Bool = false) {
        phase = .stopping
        let end = CMClockGetTime(session.stream.synchronizationClock ?? CMClockGetHostTimeClock())
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
        session = nil
        activeID = nil
        phase = .idle
        stopRequested = false
        StatusBarController.shared?.indicateRecording(false)
        let completion = onStopped
        onStopped = nil
        completion?()
    }

    private static func configuration(for filter: SCContentFilter, frameRate: Int, useNativeRate: Bool) -> SCStreamConfiguration {
        let size = filter.contentRect.size
        let pixelWidth = size.width * CGFloat(filter.pointPixelScale)
        let pixelHeight = size.height * CGFloat(filter.pointPixelScale)
        let longEdge: CGFloat = frameRate > 60 ? 2560 : 3840
        let shortEdge: CGFloat = frameRate > 60 ? 1664 : 2160
        let scale = min(1, longEdge / max(pixelWidth, pixelHeight), shortEdge / min(pixelWidth, pixelHeight))

        let config = SCStreamConfiguration()
        config.width = max(2, Int(pixelWidth * scale) / 2 * 2)
        config.height = max(2, Int(pixelHeight * scale) / 2 * 2)
        // Zero lets ScreenCaptureKit follow the display's native pacing, including variable refresh.
        config.minimumFrameInterval = useNativeRate ? .zero : CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.itur_709
        config.showsCursor = true
        config.queueDepth = 6
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
    case encoderUnavailable, noFrames, encodingFailed

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable: "A video encoder is unavailable for this display."
        case .noFrames: "The display didn’t deliver any video frames."
        case .encodingFailed: "The video encoder couldn’t complete the recording."
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
    private var lastFrame: CMSampleBuffer?
    private var acceptingFrames = true

    init(url: URL, configuration: SCStreamConfiguration, frameRate: Int,
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
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptingFrames, type == .screen, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), status == .complete || status == .started else { return }

        let timestamp = sampleBuffer.presentationTimeStamp
        guard timestamp.isNumeric, timestamp > (lastFrame?.presentationTimeStamp ?? .negativeInfinity) else { return }
        if asset.status == .unknown {
            guard asset.startWriting() else { fail(); return }
            asset.startSession(atSourceTime: timestamp)
        }
        guard asset.status == .writing else { fail(); return }
        // Drop frames under encoder backpressure and retain only the most recent accepted frame.
        guard input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else { fail(); return }
        lastFrame = sampleBuffer
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
                let end = max(time, lastFrame.presentationTimeStamp + self.frameInterval)
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
        var timing = CMSampleTimingInfo(duration: frameInterval, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var finalFrame: CMSampleBuffer?
        if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lastFrame, sampleTimingEntryCount: 1,
                                                 sampleTimingArray: &timing, sampleBufferOut: &finalFrame) == noErr,
           let finalFrame {
            _ = input.append(finalFrame)
        }
    }

    private func fail() {
        acceptingFrames = false
        onFailure(asset.error ?? RecordingError.encodingFailed)
    }
}
