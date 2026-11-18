import CoreServices
import Foundation

/// 看着几个文件夹：里面的文件被删、被移走（包括在访达里移到废纸篓）时通知一声。
///
/// 用系统的文件事件（FSEvents）：文件夹里有变化时系统来叫，不用定时去查，平时不占资源。
/// 只告诉「这几个文件夹里有变化」，具体是哪个文件由调用的一方自己去看。
@MainActor
final class FolderWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var paths: [String] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// 换成看这些文件夹（和现在一样就什么都不做）；空的就停下
    func watch(_ folders: [String]) {
        let wanted = Array(Set(folders)).sorted()
        guard wanted != paths else { return }
        stop()
        guard !wanted.isEmpty else { return }
        paths = wanted
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        // 0.3 秒内的几次变化合成一次（一次删好几个文件时只处理一遍）
        guard let stream = FSEventStreamCreate(nil, callback, &context, wanted as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            paths = []
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)   // 在主线程回调
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        paths = []
    }
}
