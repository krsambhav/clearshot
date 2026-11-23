import CoreGraphics
import CoreML
import Foundation
import Vision

struct RecognizedText: Sendable {
    enum Method: String, Sendable {
        case accurate = "Accurate OCR"
        case accurateCPU = "Accurate OCR (CPU retry)"
        case fast = "Fast OCR"
        case fastFallback = "Fast OCR fallback"
        case barcode = "QR/barcode detection"
    }

    var text: String
    var codes: [String]
    let method: Method?

    var isEmpty: Bool { text.isEmpty && codes.isEmpty }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct RecognitionOptions: Sendable {
    var accurate = true
    var keepLineBreaks = true
    var languageCorrection = true
    var detectCodes = true
}

/// On-device text recognition with Apple Vision. Runs off the main actor; a typical selection
/// finishes in well under half a second on Apple silicon.
enum TextRecognizer {
    // Vision performs synchronous work and can spend a long time loading its models.
    // Separate queues let text, fallback text and barcodes finish independently.
    nonisolated private static let accurateQueue = DispatchQueue(label: "app.clearshot.ocr.accurate", qos: .userInitiated)
    nonisolated private static let fastQueue = DispatchQueue(label: "app.clearshot.ocr.fast", qos: .userInitiated)
    nonisolated private static let codesQueue = DispatchQueue(label: "app.clearshot.ocr.codes", qos: .userInitiated)

    enum RecognitionError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "Text recognition took too long. Try again in a few seconds."
        }
    }

    private typealias AccuratePass = (text: String, method: RecognizedText.Method)

    private enum Event: Sendable {
        case accurate(Result<AccuratePass, Error>)
        case fast(Result<String, Error>)
        case codes(Result<[String], Error>)
        case timedOut
    }

    @concurrent
    nonisolated static func recognize(_ image: CGImage, options: RecognitionOptions) async throws -> RecognizedText {
        if !options.accurate && !options.detectCodes {
            let text = try readText(in: image, options: options, level: .fast)
            return RecognizedText(text: text, codes: [], method: text.isEmpty ? nil : .fast)
        }

        let (events, continuation) = AsyncStream<Event>.makeStream()
        let accurate = DispatchWorkItem {
            continuation.yield(.accurate(Result {
                do {
                    return (try readText(in: image, options: options, level: .accurate), .accurate)
                } catch {
                    return (try readText(in: image, options: options, level: .accurate, preferCPU: true), .accurateCPU)
                }
            }))
        }
        let fast = DispatchWorkItem {
            continuation.yield(.fast(Result { try readText(in: image, options: options, level: .fast) }))
        }
        let codes = DispatchWorkItem {
            continuation.yield(.codes(Result { try readCodes(in: image) }))
        }
        let timeout = DispatchWorkItem { continuation.yield(.timedOut) }
        defer {
            continuation.finish()
            accurate.cancel()
            fast.cancel()
            codes.cancel()
            timeout.cancel()
        }

        if options.accurate { accurateQueue.async(execute: accurate) }
        fastQueue.asyncAfter(deadline: .now() + (options.accurate ? .milliseconds(650) : .milliseconds(0)), execute: fast)
        if options.detectCodes { codesQueue.async(execute: codes) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: timeout)

        var accurateResult: Result<AccuratePass, Error>?
        var fastResult: Result<String, Error>?
        var codesResult: Result<[String], Error>? = options.detectCodes ? nil : .success([])
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .accurate(let result): accurateResult = result
            case .fast(let result): fastResult = result
            case .codes(let result): codesResult = result
            case .timedOut:
                if let codes = try? codesResult?.get(), !codes.isEmpty {
                    return RecognizedText(text: "", codes: codes, method: .barcode)
                }
                throw RecognitionError.timedOut
            }

            let codes = try? codesResult?.get()
            if let pass = try? accurateResult?.get(), !pass.text.isEmpty {
                return RecognizedText(text: pass.text, codes: codes ?? [], method: pass.method)
            }
            if let fastResult {
                if let text = try? fastResult.get(), !text.isEmpty {
                    let method: RecognizedText.Method = options.accurate ? .fastFallback : .fast
                    return RecognizedText(text: text, codes: codes ?? [], method: method)
                }
                if let codes, !codes.isEmpty {
                    return RecognizedText(text: "", codes: codes, method: .barcode)
                }
                if (!options.accurate || accurateResult != nil), let codesResult {
                    let text = try (try? accurateResult?.get().text) ?? fastResult.get()
                    return RecognizedText(text: text, codes: try codesResult.get(), method: nil)
                }
            }
        }
        throw CancellationError()
    }

    nonisolated private static func readText(
        in image: CGImage,
        options: RecognitionOptions,
        level: VNRequestTextRecognitionLevel,
        preferCPU: Bool = false
    ) throws -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = level
        textRequest.usesLanguageCorrection = options.languageCorrection
        textRequest.automaticallyDetectsLanguage = true
        // Small UI text is common in screenshots; let Vision look at everything.
        textRequest.minimumTextHeight = 0

        if preferCPU {
            for (stage, devices) in try textRequest.supportedComputeStageDevices {
                for case let .cpu(device) in devices {
                    textRequest.setComputeDevice(.cpu(device), for: stage)
                }
            }
        }

        try VNImageRequestHandler(cgImage: image).perform([textRequest])
        return layout(textRequest.results ?? [], keepLineBreaks: options.keepLineBreaks)
    }

    nonisolated private static func readCodes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let codes = (request.results ?? []).compactMap(\.payloadStringValue)
        return Array(NSOrderedSet(array: codes)) as? [String] ?? codes
    }

    private struct Fragment {
        let text: String
        let box: CGRect // normalized, origin top-left
    }

    /// Rebuilds reading order: fragments → lines → paragraphs.
    nonisolated private static func layout(_ observations: [VNRecognizedTextObservation], keepLineBreaks: Bool) -> String {
        let fragments: [Fragment] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return Fragment(text: candidate.string, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        guard !fragments.isEmpty else { return "" }

        // Group into lines by vertical overlap.
        var lines: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let index = lines.lastIndex(where: { line in
                guard let first = line.first else { return false }
                let overlap = min(first.box.maxY, fragment.box.maxY) - max(first.box.minY, fragment.box.minY)
                return overlap > min(first.box.height, fragment.box.height) * 0.5
            }) {
                lines[index].append(fragment)
            } else {
                lines.append([fragment])
            }
        }

        struct Line {
            let text: String
            let box: CGRect
        }
        let built: [Line] = lines.map { line in
            let sorted = line.sorted { $0.box.minX < $1.box.minX }
            let box = sorted.dropFirst().reduce(sorted[0].box) { $0.union($1.box) }
            var text = ""
            var previous: Fragment?
            for fragment in sorted {
                if let previous {
                    // Wide horizontal gaps usually separate table cells.
                    let gap = fragment.box.minX - previous.box.maxX
                    text += gap > previous.box.height * 2.5 ? "\t" : " "
                }
                text += fragment.text
                previous = fragment
            }
            return Line(text: text, box: box)
        }

        let heights = built.map(\.box.height).sorted()
        let medianHeight = heights[heights.count / 2]

        var output = ""
        for (index, line) in built.enumerated() {
            guard index > 0 else { output = line.text; continue }
            let previous = built[index - 1]
            let gap = line.box.minY - previous.box.maxY
            let paragraphBreak = gap > medianHeight * 0.9
            if paragraphBreak {
                output += "\n\n"
            } else if keepLineBreaks {
                output += "\n"
            } else if output.hasSuffix("-") {
                output.removeLast()
            } else {
                output += " "
            }
            output += line.text
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
