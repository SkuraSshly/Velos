#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit

/// 录屏里有没有 Velos 自己的提示音（只编进调试版）。
///
/// 背景（实测）：录制范围只要排除了 Velos 的任何一个窗口（录屏要排除控制条、红框），系统就不再把 Velos 自己的声音交给录屏，
/// 所以录制中的提示音由录制引擎直接混进音轨（ScreenRecorder.mixInOwnSound）。
/// 这里照真实录屏的样子录 2 秒：整块屏幕缩成 16×16 像素（看不出内容，也不看画面），排除 Velos 的一个小窗口，
/// 中间放一声「咔嚓」，再从视频的音轨里读出那一刻有多响；读完删掉视频。
/// 用法：open --env VELOS_SOUNDTEST=/输出目录 build/Velos.app
@MainActor
enum DebugSoundTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOS_SOUNDTEST"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let soundsWereOn = Preferences.shared.soundEffects
            Preferences.shared.soundEffects = true
            let line = await measure(dir: dir)
            Preferences.shared.soundEffects = soundsWereOn
            try? line.write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            DebugUITest.quitAfterTest()
        }
    }

    private static func measure(dir: URL) async -> String {
        // 和录屏排除控制条、红框一样：排除 Velos 的一个小窗口
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 60, height: 20), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .systemOrange
        window.orderFrontRegardless()
        defer { window.close() }
        do {
            try? await Task.sleep(for: .milliseconds(300))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return "没有显示器" }
            let excluded = content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
            let url = dir.appendingPathComponent("sound-test.mp4")
            try? FileManager.default.removeItem(at: url)
            let settings = ScreenRecorder.Settings(
                filter: SCContentFilter(display: display, excludingWindows: excluded),
                sourceRect: CGRect(x: 0, y: 0, width: display.width, height: display.height), pixelWidth: 16, pixelHeight: 16,
                fps: 30, showsCursor: false, codec: .h264, quality: .high, isWideGamut: false,
                capturesSystemAudio: true, capturesMicrophone: false, microphoneDeviceID: nil, outputURL: url)
            let recorder = try ScreenRecorder(settings: settings)
            try await recorder.start()
            try? await Task.sleep(for: .milliseconds(1000))
            let playedAt = recorder.elapsed
            // 和录制中一样：放出声音，同时混进音轨（RecordingManager.ownSoundPlayed 做的事）
            let shutter = SynthesizedSound.shutter
            SoundEffects.play(.shutter)
            recorder.mixInOwnSound(shutter)
            try? await Task.sleep(for: .milliseconds(1200))
            let saved = try await recorder.stop()
            defer { try? FileManager.default.removeItem(at: saved) }

            let peaks = try await audioPeaks(of: saved)
            let before: Float = peaks.filter { $0.time < playedAt - 0.1 }.map { $0.peak }.max() ?? 0
            let during: Float = peaks.filter { $0.time >= playedAt - 0.1 && $0.time <= playedAt + 0.6 }.map { $0.peak }.max() ?? 0
            let expected: Float = shutter.map { abs($0) }.max() ?? 0
            let ok = during > expected * 0.5 && during < expected * 1.5 && before < 0.01
            let text = String(format: "放的那一刻最大 %.4f（「咔嚓」本身最大 %.4f，翻倍就是重复了），之前最大 %.4f", during, expected, before)
            return (ok ? "✓" : "✗") + " 录屏里有「咔嚓」且只有一份：" + text
        } catch {
            return "✗ 出错 \(error.localizedDescription)"
        }
    }

    /// 视频音轨里每一小块的时间和最大振幅
    private static func audioPeaks(of url: URL) async throws -> [(time: Double, peak: Float)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var peaks: [(time: Double, peak: Float)] = []
        while let buffer = output.copyNextSampleBuffer() {
            var peak: Float = 0
            try? buffer.withAudioBufferList { list, _ in
                for b in list {
                    guard let data = b.mData else { continue }
                    let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for i in 0..<count { peak = max(peak, abs(samples[i])) }
                }
            }
            peaks.append((CMTimeGetSeconds(buffer.presentationTimeStamp), peak))
        }
        return peaks
    }
}
#endif
