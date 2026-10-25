import Foundation
import CoreGraphics
import CoreVideo
import CoreMedia

@main struct VideoEncoderChecks {
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let converted = try annexBFrame(Data([0,0,0,2,0x65,0x01]))
        guard converted == Data([0,0,0,1,0x65,0x01]) else { fatalError("Invalid NAL conversion") }
        for invalid: Data in [Data(), Data([0,0]), Data([0,0,0,4,1]), Data([0,0,0,0])] {
            do { _ = try annexBFrame(invalid); fatalError("Accepted broken NAL framing") } catch {}
        }
        let encoder = VideoEncoder()
        let lock = NSLock()
        var frames = 0, configs = 0, bytes = 0
        var failed: String?
        try encoder.start(handler: { packet in
            lock.lock()
            if packet.configuration { configs += 1 } else { frames += 1; bytes += packet.data.count }
            lock.unlock()
            packet.accepted()
        }, failure: { message in lock.lock(); failed = message; lock.unlock() })
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == 0, let pool else { fatalError("No pixel pool") }
        let begin = CFAbsoluteTimeGetCurrent()
        for index in 0..<240 {
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == 0, let buffer = created else { fatalError("No pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(index % 60) / 60, green: 0.1, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: index * 6, y: 100, width: 200, height: 800))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !encoder.submit(buffer, CMTime(value: Int64(index), timescale: 60)) {
                guard CFAbsoluteTimeGetCurrent() - begin < 15 else { fatalError("Encoder stalled") }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        encoder.stop()
        let elapsed = CFAbsoluteTimeGetCurrent() - begin
        guard failed == nil, frames == 240, configs > 0 else { fatalError("Encoder failed: \(failed ?? "wrong frame count \(frames)")") }
        print(String(format: "PASS: hardware H.264 1920x1080, %d frames, %d SPS/PPS packets, %.2f seconds, %.2f frames/s encoding throughput, %d bytes", frames, configs, elapsed, Double(frames)/elapsed, bytes))
        guard Double(frames) / elapsed >= 60 else { fatalError("Insufficient local encoding throughput for the requested target") }
    }
}
