import AppKit

@main struct VideoEndToEnd {
    @MainActor static func main() {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 4,
            let pin = ProcessInfo.processInfo.environment["BLUESCREEN_TEST_PIN"] else { throw failure("Need HOST DEVICE_NUMBER SECONDS and pairing code environment variable") }
        try FileManager.default.createDirectory(atPath: "evidence", withIntermediateDirectories: true)
        let host = CommandLine.arguments[1]
        let expected = CommandLine.arguments[2]
        let seconds = Int(CommandLine.arguments[3]) ?? 30
        let tv = TVConnection(rememberPairing: false)
        let screen = SecondScreen()
        let preview = ScreenPreview()
        var samples: [[String: Any]] = []
        do {
            tv.probe(host)
            for _ in 0..<80 {
                if !tv.fingerprint.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard tv.fingerprint == expected else { throw failure("Receiver identity mismatch or unavailable") }
            guard await tv.connect(pin: pin) else { throw failure(tv.status) }
            let mode = tv.selectedMode
            await screen.start(mode: mode)
            guard let id = screen.displayID else { throw failure(screen.status) }
            screen.showTestWindow()
            preview.onVideoFrame = tv.frameHandler()
            await preview.start(displayID: id, mode: mode)
            guard preview.running else { throw failure(preview.status) }
            for index in 1...seconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard tv.connected else { throw failure(tv.status) }
                let row: [String: Any] = ["second": index, "captured": preview.frames,
                    "accepted": tv.framesSent, "rendered": tv.renderedFrames, "rendered_fps_window": tv.renderedFPS,
                    "bytes": tv.bytesSent]
                samples.append(row)
                if index == 5, ProcessInfo.processInfo.environment["BLUESCREEN_CAPTURE_EVIDENCE"] == "1", let frame = preview.latestFrame {
                    try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "evidence/mac-full-hd-source.png"))
                }
                print(String(format: "t=%d captured=%d accepted=%d rendered=%d rendered_fps=%.3f", index, preview.frames, tv.framesSent, tv.renderedFrames, tv.renderedFPS))
            }
            let result: [String: Any] = ["width": mode.width, "height": mode.height, "target_fps": mode.fps, "samples": samples]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "evidence/full-hd-benchmark.json"), options: .atomic)
        } catch {
            preview.onVideoFrame = nil
            await preview.stop()
            tv.disconnect()
            await screen.stop()
            throw error
        }
        preview.onVideoFrame = nil
        await preview.stop()
        tv.disconnect()
        await screen.stop()
        print("PASS: real Full HD capture, hardware encoding, TLS transport and Android rendering completed; inspect actual FPS samples separately")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlueScreen.Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
