// 晾衣绳的声音照 Tendedero（https://github.com/alejandrobujan/tendedero，Copyright (c) 2026 Alejandro Buján，MIT，
// 见 THIRD_PARTY_NOTICES.md）：截图只有系统截图的快门声，飞上绳时不再另响；没有快门声的（剪贴板、访达挂上来的）、
// 撤销放回、钉在绳上「叮」（Tink，0.35）；取下「啵」（Pop，0.25）；删除文件是程序坞的「拖到废纸篓」。
// 声音在后台线程开始播放（系统准备声音要一两帧，放在主线程会让同时进行的动画顿一下）。
// 录屏开始 / 结束是系统录屏的提示音，倒计时每秒一声短的 Morse。

import AppKit

/// 操作时的小声音（设置 › 通用 › 声音，默认开）。
///
/// 全部用 macOS 自带的系统声音，不打包任何音频文件。每种声音第一次用到时才读进来，之后重复用同一个
/// （读的是文件的引用，不把整个声音复制进内存）；没开声音时什么都不读。
@MainActor
enum SoundEffects {
    enum Effect {
        /// 截图完成：系统截图的快门声
        case shutter
        /// 挂到晾衣绳上（没有快门声的）、撤销放回、钉在绳上
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
            case .shutter: 1
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

    /// 每种声音读一次（读的是文件的引用），之后每次放复制一份：几声可以叠着放，互不打断
    private static var loaded: [Effect: NSSound] = [:]
    private static let queue = DispatchQueue(label: "local.velos.sounds", qos: .userInitiated)

    static func play(_ effect: Effect) {
        guard Preferences.shared.soundEffects else { return }
        guard let prototype = loaded[effect] ?? effect.load() else { return }
        loaded[effect] = prototype
        guard let sound = prototype.copy() as? NSSound else { return }
        sound.volume = effect.volume
        queue.async { sound.play() }
    }
}
