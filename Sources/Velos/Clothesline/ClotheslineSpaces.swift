// 调度中心检测移植自 Picline（https://github.com/Xinguangcuican/Picline）的 Overview，
// Picline 是 Tendedero（https://github.com/alejandrobujan/tendedero，Copyright (c) 2026 Alejandro Buján）的修改分支，
// MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。

import AppKit

/// 调度中心、App Exposé、启动台开着没有。
///
/// 它们都由程序坞画：每块屏幕上盖一个和屏幕一样大的窗口。在调度中心里把窗口拖到另一个桌面，
/// 正好是「按住鼠标、拖到屏幕顶上」——和拖图片挂上绳子一模一样。所以调度中心开着时晾衣绳要让开，
/// 开着时出现了也立刻收起，免得接走本来要放到另一个桌面的东西。
/// 读的是窗口列表（谁在前台、菜单栏归谁在调度中心里都不变）；读一次比较费，最多 0.2 秒读一次，
/// 而且只在鼠标到了屏幕顶上、或绳子放下来时才读。
///
/// 程序坞不自动隐藏时，程序坞自己就一直有一个和屏幕一样大的窗口（层级、大小和调度中心的完全一样，分不出来），
/// 这时不判断调度中心（当作没开）：不然绳子永远放不下来、放下来一动鼠标又收回去。
@MainActor
enum ClotheslineOverview {
    private static let probeInterval: TimeInterval = 0.2
    private static var lastProbe: (at: Date, up: Bool)?

    static func isUp(now: Date = Date()) -> Bool {
        if let lastProbe, now.timeIntervalSince(lastProbe.at) < probeInterval { return lastProbe.up }
        let up = dockAutohides && coversAScreen(owner: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier)
        lastProbe = (now, up)
        return up
    }

    /// 程序坞设成了自动隐藏（系统设置 › 桌面与程序坞）。只有这时，程序坞的全屏窗口才说明调度中心开着
    private static var dockAutohides: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? true
    }

    /// 程序坞有一个（几乎）和屏幕一样大的窗口：调度中心开着（程序坞自动隐藏时，它平时没有这样的窗口）
    private static func coversAScreen(owner pid: pid_t?) -> Bool {
        guard let pid,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { continue }
            if screens.contains(where: { width >= $0.width * 0.9 && height >= $0.height * 0.9 }) { return true }
        }
        return false
    }
}
