import AppKit
import Combine
import ScreenCaptureKit
import CoreImage

@MainActor final class ScreenPreview: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published private(set) var image: NSImage?
    @Published private(set) var frames = 0
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var status = "Предпросмотр выключен. На телевизор изображение не передаётся."
    private var capture: SCStream?
    private(set) var latestFrame: CGImage?
    private nonisolated let videoFrames = CaptureFrames()
    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { nil }
        set { videoFrames.set(newValue) }
    }
    func sendLatestVideoFrame() { videoFrames.emitLatest() }
    private nonisolated let context = CIContext(options: [.cacheIntermediates: false])

    func start(displayID: UInt32) async {
        guard !busy, !running else { return }
        guard CGPreflightScreenCaptureAccess() else {
            status = "Нужно разрешение macOS на запись экрана. Без него предпросмотр не запускается."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(domain: "BlueScreen.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Второй экран не найден для захвата."])
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 1920
            configuration.height = 1080
            // The virtual screen is 60 Hz; avoid capture-side phase throttling at the same cadence.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            configuration.queueDepth = 3
            configuration.capturesAudio = false
            configuration.showsCursor = true
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "local.bluescreen.preview", qos: .userInitiated))
            capture = stream
            frames = 0
            videoFrames.reset()
            try await stream.startCapture()
            running = true
            status = "Локальный предпросмотр второго экрана. Звук не захватывается, файлы не записываются."
        } catch {
            let stream = capture
            capture = nil
            try? await stream?.stopCapture()
            status = "Предпросмотр не запущен: \(error.localizedDescription)"
        }
    }

    func stop() async {
        let stream = capture
        capture = nil
        running = false
        image = nil
        latestFrame = nil
        videoFrames.reset()
        try? await stream?.stopCapture()
        status = "Предпросмотр выключен."
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let progress = videoFrames.consume(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard progress.preview else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(frame, from: frame.extent) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.capture === stream else { return }
            self.image = NSImage(cgImage: cgImage, size: NSSize(width: 1920, height: 1080))
            self.latestFrame = cgImage
            self.frames = progress.count
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.capture === stream else { return }
            self.capture = nil
            self.running = false
            self.image = nil
            self.status = "Захват остановлен: \(error.localizedDescription)"
        }
    }
}

private final class CaptureFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CVPixelBuffer, CMTime) -> Void)?
    private var count = 0
    private var lastPreview: Double = 0
    private var latest: (CVPixelBuffer, CMTime)?
    func set(_ value: ((CVPixelBuffer, CMTime) -> Void)?) { lock.lock(); handler = value; lock.unlock() }
    func reset() { lock.lock(); count = 0; lastPreview = 0; latest = nil; lock.unlock() }
    func emitLatest() {
        lock.lock(); let frame = latest; let handler = handler; lock.unlock()
        if let frame { handler?(frame.0, frame.1) }
    }
    func consume(_ buffer: CVPixelBuffer, _ time: CMTime) -> (preview: Bool, count: Int) {
        lock.lock()
        count += 1
        latest = (buffer, time)
        let preview = time.seconds - lastPreview >= 0.2
        if preview { lastPreview = time.seconds }
        let total = count
        let callback = handler
        lock.unlock()
        callback?(buffer, time)
        return (preview, total)
    }
}
