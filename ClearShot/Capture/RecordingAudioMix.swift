import AVFoundation

/// Combines the two captured audio sources into one playback track, copying the encoded video.
nonisolated final class RecordingAudioMix: @unchecked Sendable {
    static let aacSettings: [String: Int] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "app.clearshot.recording.mix", qos: .userInitiated)
    private var remainingInputs = 2
    private var continuation: CheckedContinuation<Void, Error>?

    private init(asset: AVURLAsset, destination: URL) throws {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    }

    static func replaceAudioTracks(in source: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await videoTrack.load(.formatDescriptions).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let destination = source.appendingPathExtension("mixed.mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let mix = try RecordingAudioMix(asset: asset, destination: destination)

        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audio = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        let levels = AVMutableAudioMix()
        levels.inputParameters = audioTracks.map { track in
            let level = AVMutableAudioMixInputParameters(track: track)
            level.setVolume(0.5, at: .zero)
            return level
        }
        audio.audioMix = levels

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        guard mix.reader.canAdd(video), mix.reader.canAdd(audio),
              mix.writer.canAdd(videoInput), mix.writer.canAdd(audioInput) else {
            throw CocoaError(.fileWriteUnknown)
        }
        mix.reader.add(video)
        mix.reader.add(audio)
        mix.writer.add(videoInput)
        mix.writer.add(audioInput)
        mix.writer.movieTimeScale = 60_000
        try await mix.write(video: video, to: videoInput, audio: audio, to: audioInput)
        _ = try FileManager.default.replaceItemAt(source, withItemAt: destination)
    }

    private func write(video: AVAssetReaderOutput, to videoInput: AVAssetWriterInput,
                       audio: AVAssetReaderOutput, to audioInput: AVAssetWriterInput) async throws {
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            transfer(video, to: videoInput)
            transfer(audio, to: audioInput)
        }
    }

    private func transfer(_ output: AVAssetReaderOutput, to input: AVAssetWriterInput) {
        // The writer calls this again after backpressure clears. Both inputs share a queue.
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        input.requestMediaDataWhenReady(on: queue) {
            while self.continuation != nil, input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    if self.reader.status == .failed {
                        self.fail(self.reader.error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    input.markAsFinished()
                    self.remainingInputs -= 1
                    if self.remainingInputs == 0, let continuation = self.continuation {
                        self.continuation = nil
                        self.writer.finishWriting {
                            if self.writer.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: self.writer.error ?? CocoaError(.fileWriteUnknown)) }
                        }
                    }
                    return
                }
                guard input.append(sample) else {
                    self.fail(self.writer.error ?? CocoaError(.fileWriteUnknown))
                    return
                }
            }
        }
    }

    private func fail(_ error: Error) {
        reader.cancelReading()
        writer.cancelWriting()
        let completion = continuation
        continuation = nil
        completion?.resume(throwing: error)
    }
}
