import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox

@main struct AudioPCMChecks {
    static func main() throws {
        for (channels, expected) in [(1, [16384, 16384]), (2, [16384, -16384])] {
            let frames = 1024
            let samples: [Float] = channels == 1
                ? Array(repeating: 0.5, count: frames)
                : (0..<frames).flatMap { _ in [Float(0.5), Float(-0.5)] }
            let bytes = frames * channels * 4
            var asbd = AudioStreamBasicDescription(mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(channels * 4),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            var block: CMBlockBuffer?
            var sample: CMSampleBuffer?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format) == noErr,
                CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
                let format, let block else { fatalError("Audio sample allocation failed") }
            let copied = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: bytes)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var size = channels * 4
            guard copied == noErr,
                CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                    formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                    sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample,
                let pcm = AudioPCM.encode(sample),
                pcm.count == frames * AudioPCM.bytesPerFrame else {
                fatalError("AudioPCM rejected valid \(channels)-channel Float32")
            }
            pcm.withUnsafeBytes { raw in
                let data = raw.bindMemory(to: Int16.self)
                for i in 0..<frames {
                    guard data[2*i] == expected[0], data[2*i+1] == expected[1] else {
                        fatalError("Stereo conversion mismatch for \(channels) channels")
                    }
                }
            }
        }
        print("PASS: 48 kHz Float32 mono/stereo to 16-bit stereo PCM; duplicate mono and preserve channels")
    }
}
