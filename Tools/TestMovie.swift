import AVFoundation
import CoreText

@main struct TestMovie {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "BlueScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output already exists"])
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000, AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
                kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { fatalError("Cannot add encoder") }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(30)
        for frame in 0..<240 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? NSError(domain: "EncodingTimeout", code: 1) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { fatalError("No buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1280, height: 720,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.02, green: 0.08, blue: 0.18, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 1, alpha: 1))
            context.fill(CGRect(x: 80 + frame * 4, y: 160, width: 120, height: 120))
            draw("BlueScreen TV", at: CGPoint(x: 80, y: 560), size: 64, context: context)
            draw("SYNTHETIC TEST — NO SCREEN OR AUDIO", at: CGPoint(x: 80, y: 450), size: 30, context: context)
            draw(String(format: "1280 x 720  |  frame %03d  |  %.2f s", frame, Double(frame) / 30),
                at: CGPoint(x: 80, y: 350), size: 32, context: context)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw writer.error ?? NSError(domain: "EncodingTimeout", code: 2)
        }
        print("PASS: synthetic H.264 video, 1280x720, 240 frames, no audio or captured screen")
    }
    static func draw(_ text: String, at point: CGPoint, size: CGFloat, context: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), context)
    }
}
