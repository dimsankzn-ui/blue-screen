import Foundation
import VideoToolbox

struct VideoPacket {
    let data: Data
    let configuration: Bool
    let timestamp: UInt64
    let accepted: () -> Void
}

final class VideoEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.bluescreen.h264", qos: .userInitiated)
    private var session: VTCompressionSession?
    private var budget = DispatchSemaphore(value: 6)
    private var handler: ((VideoPacket) -> Void)?
    private var failure: ((String) -> Void)?
    private var origin: CMTime?
    private var previousTime: CMTime?
    private var frameRateMilli: Int = 60000
    private var usesHEVC = false

    func start(mode: DisplayMode = .fullHD, handler: @escaping (VideoPacket) -> Void, failure: @escaping (String) -> Void) throws {
        try queue.sync {
            guard session == nil else { return }
            var created: VTCompressionSession?
            let hevc = mode.codec == "hevc"
            var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if !hevc { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            try check(VTCompressionSessionCreate(allocator: nil, width: Int32(mode.width), height: Int32(mode.height),
                codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created))
            guard let created else { throw error("Аппаратный видеокодер недоступен.") }
            do {
                let properties: [CFString: Any] = [
                    kVTCompressionPropertyKey_RealTime: true,
                    kVTCompressionPropertyKey_AllowFrameReordering: false,
                    kVTCompressionPropertyKey_ExpectedFrameRate: Int(ceil(mode.fps)),
                    kVTCompressionPropertyKey_AverageBitRate: min(80_000_000, max(2_000_000, Int(18_000_000 * Double(mode.width * mode.height) / (1920 * 1080) * mode.fps / 60))),
                    kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(ceil(mode.fps * 2)),
                    kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel]
                for (key, value) in properties {
                    let status = VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
                    guard status == noErr else { throw error("VideoToolbox \(key): \(status)") }
                }
                let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
                guard prepared == noErr else { throw error("VideoToolbox prepare: \(prepared)") }
                var hardware: Unmanaged<CFTypeRef>?
                let inspected = VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    allocator: nil, valueOut: &hardware)
                // RequireHardwareAcceleratedVideoEncoder forbids software fallback.
                // This encoder does not necessarily expose the optional readback property.
                if inspected == noErr {
                    guard hardware?.takeRetainedValue() as? Bool == true else { throw error("macOS не подтвердила аппаратное кодирование.") }
                } else if inspected != kVTPropertyNotSupportedErr {
                    throw error("VideoToolbox inspect hardware: \(inspected)")
                }
            } catch { VTCompressionSessionInvalidate(created); throw error }
            usesHEVC = hevc
            frameRateMilli = mode.fpsMilli
            session = created
            budget = DispatchSemaphore(value: 6)
            self.handler = handler
            self.failure = failure
            origin = nil
            previousTime = nil
        }
    }

    @discardableResult func submit(_ buffer: CVPixelBuffer, _ time: CMTime) -> Bool {
        queue.sync { [self] in
            if let previousTime, CMTimeCompare(time, previousTime) <= 0 { return false }
            guard let session, let handler, budget.wait(timeout: .now()) == .success else { return false }
            if origin == nil { origin = time }
            previousTime = time
            let relative = CMTimeSubtract(time, origin!)
            let hevc = usesHEVC
            let credit = budget
            let failure = failure
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                presentationTimeStamp: relative, duration: CMTime(value: 1000, timescale: Int32(frameRateMilli)),
                frameProperties: nil, infoFlagsOut: nil) { status, flags, sample in
                    guard status == noErr, !flags.contains(.frameDropped), let sample, CMSampleBufferDataIsReady(sample) else {
                        credit.signal()
                        if status != noErr { failure?("Ошибка аппаратного кодера: \(status)") }
                        return
                    }
                    do {
                        let attachment = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                        let keyframe = attachment?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
                        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
                            var config = Data()
                            for index in 0..<(hevc ? 3 : 2) {
                                var pointer: UnsafePointer<UInt8>?
                                var size = 0
                                if hevc {
                                    try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil))
                                } else {
                                    try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil))
                                }
                                guard let pointer else { throw error("Нет параметров H.264.") }
                                config.append(contentsOf: [0,0,0,1])
                                config.append(pointer, count: size)
                            }
                            handler(VideoPacket(data: config, configuration: true, timestamp: 0, accepted: {}))
                        }
                        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw error("Нет видеоданных.") }
                        var bytes = Data(count: CMBlockBufferGetDataLength(block))
                        let copied = bytes.withUnsafeMutableBytes { pointer in
                            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: pointer.count, destination: pointer.baseAddress!)
                        }
                        try check(copied)
                        let annexB = try annexBFrame(bytes)
                        let micros = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value
                        handler(VideoPacket(data: annexB, configuration: false, timestamp: UInt64(max(0, micros)), accepted: { credit.signal() }))
                    } catch {
                        credit.signal()
                        failure?(error.localizedDescription)
                    }
                }
            if result != noErr { credit.signal(); failure?("Не удалось передать кадр кодеру: \(result)") }
            return result == noErr
        }
    }

    func stop() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            handler = nil
            failure = nil
        }
    }
}

func annexBFrame(_ bytes: Data) throws -> Data {
    var offset = 0
    var result = Data()
    while offset < bytes.count {
        guard bytes.count - offset >= 4 else { throw error("Оборван заголовок H.264.") }
        let length = bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        guard length > 0, Int(length) <= bytes.count - offset else { throw error("Оборван видеокадр H.264.") }
        result.append(contentsOf: [0,0,0,1])
        result.append(bytes[offset..<offset+Int(length)])
        offset += Int(length)
    }
    guard !result.isEmpty else { throw error("Пустой видеокадр.") }
    return result
}

private func error(_ message: String) -> NSError {
    NSError(domain: "BlueScreen.H264", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
private func check(_ status: OSStatus) throws {
    guard status == noErr else { throw error("VideoToolbox: \(status)") }
}
