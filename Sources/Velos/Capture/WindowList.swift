import AppKit

/// 冻屏那一刻屏幕上的一个窗口
struct DetectedWindow: Equatable {
    /// 窗口的位置（AppKit 全局坐标，单位：点）
    let frame: CGRect
    /// 窗口编号（合成画面里是 0）：带阴影截图时用它读出窗口的圆角
    var id: CGWindowID = 0
    /// 普通 App 窗口（不是菜单栏、程序坞、浮动面板）：整个窗口截图时可以带上圆角和阴影
    var isAppWindow = false
}

/// 冻屏那一刻屏幕上的窗口位置，用于鼠标悬停时自动识别窗口。
/// 只读取窗口的位置和层级（CGWindowListCopyWindowInfo），不截取任何窗口内容。
enum WindowList {
    /// 按从前到后的顺序返回窗口
    /// - Parameter includingOwn: Velos 自己的窗口中仍要参与识别的（钉图）
    static func snapshot(includingOwn: Set<CGWindowID> = []) -> [DetectedWindow] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let maxLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

        return infos.compactMap { info -> DetectedWindow? in
            let number = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            let isOwn = (info[kCGWindowOwnerPID as String] as? pid_t) == ownPID
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  (0..<maxLayer).contains(layer),                                   // 普通窗口、浮动面板、菜单栏、程序坞等
                  !isOwn || includingOwn.contains(number),                          // 不识别 Velos 自己的界面，设置、钉图等普通窗口除外
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,          // 跳过完全透明的辅助窗口
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 4, bounds.height >= 4 else { return nil }
            // CoreGraphics 坐标原点在主屏左上角，AppKit 在主屏左下角，翻转 y
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return DetectedWindow(frame: frame, id: number, isAppWindow: layer == 0 && !isOwn)
        }
    }
}
