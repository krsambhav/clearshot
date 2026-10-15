import CoreGraphics
import Foundation
import Vision

struct RecognizedText: Sendable {
    var text: String
    var codes: [String]

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
    @concurrent
    nonisolated static func recognize(_ image: CGImage, options: RecognitionOptions) async throws -> RecognizedText {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = options.accurate ? .accurate : .fast
        textRequest.usesLanguageCorrection = options.languageCorrection
        textRequest.automaticallyDetectsLanguage = true
        // Small UI text is common in screenshots; let Vision look at everything.
        textRequest.minimumTextHeight = 0

        var requests: [VNRequest] = [textRequest]
        let codeRequest = VNDetectBarcodesRequest()
        if options.detectCodes { requests.append(codeRequest) }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(requests)

        let observations = textRequest.results ?? []
        let text = layout(observations, keepLineBreaks: options.keepLineBreaks)
        let codes = options.detectCodes ? (codeRequest.results ?? []).compactMap(\.payloadStringValue) : []
        return RecognizedText(text: text, codes: Array(NSOrderedSet(array: codes)) as? [String] ?? codes)
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
