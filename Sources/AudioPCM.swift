import CoreMedia
import CoreAudio
import AudioToolbox

// ScreenCaptureKit provides float PCM. The TV receives little-endian 16-bit
// stereo at 48 kHz; macOS keeps playing through its own output unchanged.
enum AudioPCM {
    static let sampleRate = 48_000
    static let channels = 2
    static let bytesPerFrame = 4

    static func encode(_ sample: CMSampleBuffer) -> Data? {
        guard sample.isValid,
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mSampleRate == Double(sampleRate),
              (asbd.mChannelsPerFrame == 1 || asbd.mChannelsPerFrame == 2) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 && frames <= 8192 else { return nil }
        var needed = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil)
        guard needed >= MemoryLayout<AudioBufferList>.size && needed <= 4096 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: needed)
        let listPointer = storage.assumingMemoryBound(to: AudioBufferList.self)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        guard buffers.count >= 1 else { return nil }
        // Handles stereo interleaved and stereo planar buffers; mono is duplicated.
        let planar = buffers.count >= 2 && buffers[0].mNumberChannels == 1 && buffers[1].mNumberChannels == 1
        guard let first = buffers[0].mData else { return nil }
        let mono = asbd.mChannelsPerFrame == 1
        guard Int(buffers[0].mDataByteSize) >= frames * (planar || mono ? 4 : 8) else { return nil }
        let left = first.assumingMemoryBound(to: Float.self)
        var right = left
        if planar {
            guard let second = buffers[1].mData, Int(buffers[1].mDataByteSize) >= frames * 4 else { return nil }
            right = second.assumingMemoryBound(to: Float.self)
        }
        var result = Data(count: frames * bytesPerFrame)
        result.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                let a = left[index * (planar || mono ? 1 : 2)]
                let b = mono ? a : right[index * (planar ? 1 : 2) + (planar ? 0 : 1)]
                for (channel, value) in [a,b].enumerated() {
                    let safe = value.isFinite ? max(-1, min(1, value)) : 0
                    let signed = Int16((safe * 32767).rounded())
                    let bits = UInt16(bitPattern: signed).littleEndian
                    let offset = index * bytesPerFrame + channel * 2
                    bytes[offset] = UInt8(truncatingIfNeeded: bits)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
        }
        return result
    }
}
