// 截图、晾衣绳的声音照 Tendedero 的网站（https://tendedero.app，js/util.js 的 sound；作者 Alejandro Buján，
// Tendedero 以 MIT 许可证开源，见 THIRD_PARTY_NOTICES.md）：不用声音文件，当场合成——
// 快门是两小段滤过的噪声，「叮」是两个高音，拿下 / 删除是一段低沉的噪声加一个低音，发给别的 App 是两个上扬的音。
// 什么时候响也照网站：截图「咔嚓」后马上挂上绳「叮」；取下、删除、拖到废纸篓都是同一声；拖进别的 App「嗖」，拖进访达不响。
// 录屏倒计时、开始 / 结束（网站上没有）用系统的提示音。

import AppKit

/// 操作时的小声音（设置 › 通用 › 声音，默认开）。
///
/// 截图和晾衣绳的声音在第一次用到时合成成一小段声音（几十 KB，存在内存里重复用），录屏的用系统自带的声音；
/// 不打包任何音频文件。没开声音时什么都不做。声音在后台线程开始播放：准备声音要一两帧，放在主线程会让同时进行的动画顿一下。
@MainActor
enum SoundEffects {
    enum Effect {
        /// 截图完成：「咔嚓」
        case shutter
        /// 挂到晾衣绳上、撤销放回、钉在绳上：「叮」
        case hang
        /// 从晾衣绳上取下（✕、Delete、右键取下、全部取下）
        case takeDown
        /// 删除文件、拖到程序坞的废纸篓上
        case trash
        /// 从绳上拖进别的 App（发过去）
        case send
        /// 录屏倒计时的每一秒（3、2、1）
        case countdown
        /// 开始录屏、结束录屏（录屏不录 Velos 自己的声音，这两声不会出现在视频里）
        case recordStart, recordStop

        fileprivate func load() -> NSSound? {
            let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
            switch self {
            case .shutter: return SynthesizedSound.shutter
            case .hang: return SynthesizedSound.tink
            case .takeDown, .trash: return SynthesizedSound.trash
            case .send: return SynthesizedSound.send
            case .countdown:
                let sound = NSSound(named: "Morse")?.copy() as? NSSound
                sound?.volume = 0.3
                return sound
            case .recordStart, .recordStop:
                let sound = NSSound(contentsOfFile: systemSounds + (self == .recordStart ? "system/begin_record.caf" : "system/end_record.caf"),
                                    byReference: true)
                sound?.volume = 0.6
                return sound
            }
        }
    }

    /// 每种声音准备一次，之后每次放复制一份：几声可以叠着放，互不打断
    private static var loaded: [Effect: NSSound] = [:]
    private static let queue = DispatchQueue(label: "local.velos.sounds", qos: .userInitiated)

    static func play(_ effect: Effect) {
        guard Preferences.shared.soundEffects else { return }
        guard let prototype = loaded[effect] ?? effect.load() else { return }
        loaded[effect] = prototype
        guard let sound = prototype.copy() as? NSSound else { return }
        queue.async { sound.play() }
    }
}

/// 照 Tendedero 网站的 Web Audio 做法合成的声音：同样的频率、长短、音量和滤波，算成一小段 WAV 交给 NSSound 放
enum SynthesizedSound {
    static let sampleRate = 48_000.0   // 和浏览器里 Web Audio 默认的一样

    /// 快门：一小段 2600 Hz 附近的噪声，75 毫秒后再一段 1800 Hz 附近的
    static var shutter: NSSound? {
        make(length: 0.16) { mix in
            mix.noise(duration: 0.05, gain: 0.22, frequency: 2600)
            mix.noise(duration: 0.07, gain: 0.18, frequency: 1800, at: 0.075)
        }
    }

    /// 叮：E7（2637 Hz）加上高五度的泛音
    static var tink: NSSound? {
        make(length: 0.25) { mix in
            mix.tone(frequency: 2637, duration: 0.22, gain: 0.05)
            mix.tone(frequency: 3951, duration: 0.12, gain: 0.018)
        }
    }

    /// 拿下、删除：一段 900 Hz 附近的噪声，稍后一个低沉的三角波
    static var trash: NSSound? {
        make(length: 0.3) { mix in
            mix.noise(duration: 0.28, gain: 0.12, frequency: 900)
            mix.tone(frequency: 180, duration: 0.2, gain: 0.03, wave: .triangle, at: 0.04)
        }
    }

    /// 发过去：两个上扬的音（A5、E6）
    static var send: NSSound? {
        make(length: 0.2) { mix in
            mix.tone(frequency: 880, duration: 0.08, gain: 0.04)
            mix.tone(frequency: 1320, duration: 0.12, gain: 0.035, at: 0.06)
        }
    }

    // MARK: - 合成

    enum Wave { case sine, triangle }

    struct Mix {
        var samples: [Float]
        /// 固定种子的噪声：每次合成出来的都一样
        var seed: UInt64 = 0x5EED

        /// 一个音：4 毫秒升到 gain，再按指数衰减，duration 秒时降到万分之一
        mutating func tone(frequency: Double, duration: Double, gain: Double, wave: Wave = .sine, at start: Double = 0) {
            let attack = 0.004
            let first = Int(start * sampleRate)
            let count = Int((duration + 0.02) * sampleRate)
            for i in 0..<count where first + i < samples.count {
                let t = Double(i) / sampleRate
                let level: Double
                if t < attack {
                    level = gain * t / attack
                } else if t < duration {
                    level = gain * pow(0.0001 / gain, (t - attack) / (duration - attack))
                } else {
                    level = 0.0001
                }
                let phase = frequency * t
                let value: Double = switch wave {
                case .sine: sin(2 * .pi * phase)
                case .triangle: 4 * abs(phase - (phase + 0.5).rounded(.down)) - 1
                }
                samples[first + i] += Float(value * level)
            }
        }

        /// 一段噪声：越往后越轻（(1 - 进度)³），再经过 frequency 附近的带通滤波（Q 0.9）
        mutating func noise(duration: Double, gain: Double, frequency: Double, at start: Double = 0) {
            let count = Int((sampleRate * duration).rounded(.up))
            let first = Int(start * sampleRate)
            // 带通滤波器的系数（和 Web Audio 的 BiquadFilter「bandpass」同一种）
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * 0.9)
            let a0 = 1 + alpha
            let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            // 噪声放完以后滤波器还会响一小会儿，一起算进去
            for i in 0..<(count + Int(0.03 * sampleRate)) where first + i < samples.count {
                var x = 0.0
                if i < count {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let random = Double(seed >> 11) / Double(1 << 53) * 2 - 1
                    x = random * pow(1 - Double(i) / Double(count), 3)
                }
                let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                samples[first + i] += Float(y * gain)
            }
        }
    }

    private static func make(length: Double, _ build: (inout Mix) -> Void) -> NSSound? {
        var mix = Mix(samples: [Float](repeating: 0, count: Int(length * sampleRate)))
        build(&mix)
        return NSSound(data: wav(mix.samples))
    }

    /// 单声道 16 位 WAV
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}
