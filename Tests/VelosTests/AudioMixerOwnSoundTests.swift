import AVFoundation
import Testing
@testable import Velos

/// 录制中 Velos 自己的提示音直接混进音轨（系统不会把 Velos 的声音交给录屏，见 RecordingManager.ownSoundPlayed）
struct AudioMixerOwnSoundTests {
    private let start = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    /// 一段静音的系统声音（和 ScreenCaptureKit 一样：48kHz 立体声浮点）
    private func silence(frames: Int, at index: Int) -> CMSampleBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 48_000)),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                             sampleSizeArray: nil, sampleBufferOut: &buffer)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                       bufferList: pcm.audioBufferList)
        return buffer!
    }

    /// 混音输出的交错立体声，按时间线上的采样序号排好
    private func samples(of outputs: [CMSampleBuffer]) -> [Float] {
        var all: [Float] = []
        for buffer in outputs {
            try? buffer.withAudioBufferList { list, _ in
                for b in list {
                    let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    all += Array(UnsafeBufferPointer(start: b.mData!.bindMemory(to: Float.self, capacity: count), count: count))
                }
            }
        }
        return all
    }

    @Test func 提示音在它放的时刻混进音轨且只有一份() throws {
        var outputs: [CMSampleBuffer] = []
        let mixer = try AudioMixer(startTime: start, sources: [.system]) { outputs.append($0) }
        let sound = [Float](repeating: 0.25, count: 4800)   // 0.1 秒
        var index = 0
        while index < 48_000 {
            // 系统声音比实际时刻晚一点才到：放提示音时（0.5 秒），系统声音才送到 0.4 秒左右
            if index == 19_456 { mixer.addOwnSound(sound, at: CMTimeAdd(start, CMTime(value: 24_000, timescale: 48_000))) }
            mixer.add(silence(frames: 1024, at: index), from: .system, at: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 48_000)))
            index += 1024
        }
        mixer.flush(final: true, until: CMTimeAdd(start, CMTime(value: 48_000, timescale: 48_000)))

        let mixed = samples(of: outputs)
        let left = stride(from: 0, to: mixed.count, by: 2).map { mixed[$0] }
        // 0.5 秒（第 24000 个采样）起的 0.1 秒是提示音，其余是静音
        #expect(left.count >= 48_000, "输出 \(left.count) 个采样")   // 送进去的系统声音是 47 块 × 1024，略多于 1 秒
        #expect(left[24_000 ..< 28_800].allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(left[0 ..< 24_000].allSatisfy { $0 == 0 })
        #expect(left[28_800...].allSatisfy { $0 == 0 })
    }

    @Test func 已经输出过的部分不再改() throws {
        var outputs: [CMSampleBuffer] = []
        let mixer = try AudioMixer(startTime: start, sources: [.system]) { outputs.append($0) }
        var index = 0
        while index < 24_576 {
            mixer.add(silence(frames: 1024, at: index), from: .system, at: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 48_000)))
            index += 1024
        }
        // 0.1 秒前的声音：输出过的开头丢掉，没输出的后半段照常混进去
        mixer.addOwnSound([Float](repeating: 0.25, count: 48_000), at: CMTimeAdd(start, CMTime(value: 4_800, timescale: 48_000)))
        mixer.flush(final: true, until: CMTimeAdd(start, CMTime(value: 48_000, timescale: 48_000)))
        let mixed = samples(of: outputs)
        let left = stride(from: 0, to: mixed.count, by: 2).map { mixed[$0] }
        #expect(left.count >= 48_000)
        #expect(left.last.map { abs($0 - 0.25) < 0.001 } == true)
    }
}
