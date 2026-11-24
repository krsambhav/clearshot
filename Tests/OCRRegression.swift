import AppKit
import Foundation
import CoreImage

@main
struct OCRRegression {
    static func main() async throws {
        // A deliberately stalled child makes fallback/recovery tests independent
        // of the OS version, hardware, and Vision's model cache.
        if CommandLine.arguments.dropFirst().first == "--clearshot-ocr-worker" {
            if ProcessInfo.processInfo.environment["CLEARSHOT_TEST_STALL_OCR"] == "1" {
                sleep(60)
                return
            }
            if ProcessInfo.processInfo.environment["CLEARSHOT_TEST_STALL_OCR"] == "success" {
                let payload = #"{"text":"Accurate worker result","method":"Accurate OCR"}"#
                try payload.write(toFile: CommandLine.arguments[3], atomically: true, encoding: .utf8)
                return
            }
            _ = TextRecognizer.runWorkerIfRequested()
            return
        }
        setenv("CLEARSHOT_TEST_STALL_OCR", "1", 1)
        let image = NSImage(size: NSSize(width: 900, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 180).fill()
        ("ClearShot OCR test 12345" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let textImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            print("PASS \(message)")
        }
        for attempt in 1...3 {
            let start = Date()
            let result = try await TextRecognizer.recognize(textImage, options: RecognitionOptions())
            check(result.text.contains("12345") && result.method == .fastFallback,
                  "Capture \(attempt) returns fast text despite a stalled accurate worker")
            check(Date().timeIntervalSince(start) < 4, "Fallback finishes before the timeout")
        }
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("clearshot-regression".utf8)])!.outputImage!
        let enlarged = qr.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let padded = enlarged.composited(over: CIImage(color: .white).cropped(to: enlarged.extent.insetBy(dx: -32, dy: -32)))
        let qrImage = CIContext().createCGImage(padded, from: padded.extent)!
        let code = try await TextRecognizer.recognize(qrImage, options: RecognitionOptions())
        check(code.codes == ["clearshot-regression"] && code.method == .barcode,
              "QR detection works while accurate OCR is stalled")
        let blank = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let empty = try await TextRecognizer.recognize(blank, options: RecognitionOptions())
        check(empty.isEmpty, "A blank selection returns no text instead of a timeout error")
        let recovered = try await TextRecognizer.recognize(textImage, options: RecognitionOptions())
        check(recovered.text.contains("12345"), "OCR still works after an accurate-worker timeout")
        let task = Task { try await TextRecognizer.recognize(blank, options: RecognitionOptions()) }
        try await Task.sleep(for: .milliseconds(150))
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("Cancelled OCR returned success")
        } catch is CancellationError {
            check(Date().timeIntervalSince(cancelledAt) < 1, "Cancellation returns promptly")
        }
        let indexed = try await TextRecognizer.recognize(textImage, options: RecognitionOptions(
            accurate: false, keepLineBreaks: false, languageCorrection: false, detectCodes: false))
        check(indexed.text.contains("12345") && indexed.method == .fast, "Background indexing uses bounded fast OCR")
        setenv("CLEARSHOT_TEST_STALL_OCR", "success", 1)
        let accurate = try await TextRecognizer.recognize(textImage, options: RecognitionOptions())
        check(accurate.text == "Accurate worker result" && accurate.method == .accurate,
              "A successful worker result retains accurate OCR priority")
        try await Task.sleep(for: .milliseconds(200))
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        children.arguments = ["-P", String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        children.standardOutput = pipe
        try children.run()
        children.waitUntilExit()
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        check(remaining.isEmpty, "No recognition worker is left running")
    }
}
