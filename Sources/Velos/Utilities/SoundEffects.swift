// 晾衣绳的声音和音量照 Picline（https://github.com/Xinguangcuican/Picline，MIT，见 THIRD_PARTY_NOTICES.md）：
// 挂上「叮」（Tink，0.35）、取下「啵」（Pop，0.25）、删除文件是程序坞的「拖到废纸篓」。
// 截图本身是系统截图的快门声，调小一点；录屏开始 / 结束是系统录屏的提示音，倒计时每秒一声短的 Morse。

import AppKit

/// 操作时的小声音（设置 › 通用 › 声音，默认开）。
///
/// 全部用 macOS 自带的系统声音，不打包任何音频文件。每种声音第一次用到时才读进来，之后重复用同一个
/// （读的是文件的引用，不把整个声音复制进内存）；没开声音时什么都不读。
@MainActor
enum SoundEffects {
    enum Effect {
        /// 截图完成：小小的「咔嚓」
        case shutter
        /// 挂到晾衣绳上
        case hang
        /// 从晾衣绳上取下
        case takeDown
        /// 删除文件（进废纸篓或永久删除）
        case trash
        /// 录屏倒计时的每一秒（3、2、1）
        case countdown
        /// 开始录屏、结束录屏（录屏不录 Velos 自己的声音，这两声不会出现在视频里）
        case recordStart, recordStop

        fileprivate var volume: Float {
            switch self {
            case .shutter: 0.4
            case .hang: 0.35
            case .takeDown: 0.25
            case .trash: 1
            case .countdown: 0.3
            case .recordStart, .recordStop: 0.6
            }
        }

        fileprivate func load() -> NSSound? {
            let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
            switch self {
            case .shutter: return NSSound(contentsOfFile: systemSounds + "system/Screen Capture.aif", byReference: true)
            case .hang: return NSSound(named: "Tink")
            case .takeDown: return NSSound(named: "Pop")
            case .trash: return NSSound(contentsOfFile: systemSounds + "dock/drag to trash.aif", byReference: true)
            case .countdown: return NSSound(named: "Morse")
            case .recordStart: return NSSound(contentsOfFile: systemSounds + "system/begin_record.caf", byReference: true)
            case .recordStop: return NSSound(contentsOfFile: systemSounds + "system/end_record.caf", byReference: true)
            }
        }
    }

    private static var loaded: [Effect: NSSound] = [:]

    static func play(_ effect: Effect) {
        guard Preferences.shared.soundEffects else { return }
        guard let sound = loaded[effect] ?? effect.load().flatMap({ $0.copy() as? NSSound }) else { return }
        // 存一份自己的（系统声音按名字拿到的是大家共用的那个，改音量会影响别人）
        loaded[effect] = sound
        sound.volume = effect.volume
        // 连着来两下（例如连续截图）：从头再放，不叠在一起
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
