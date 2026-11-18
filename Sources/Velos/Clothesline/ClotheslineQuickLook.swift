// 用 macOS 自带的快速查看看绳上的截图，思路来自 Tendedero（https://github.com/alejandrobujan/tendedero）的 QuickLook，
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 改动：加了「按住空格看、松开就关」和「点按一下一直开着、再点按关上」。

import AppKit
import Carbon.HIToolbox
import Quartz

/// 晾衣绳上的空格键：用系统自带的「快速查看」（和访达里按空格一样）看截图。
///
/// - 按住空格：打开预览，松开就关，回到原来的地方
/// - 点按空格（按下很快就松开）：预览一直开着；再点按一次空格关上（Esc 也行）
/// - 预览开着时 ← → 看绳上前一张、后一张
///
/// 空格只在鼠标停在卡片上（或预览开着）时借用：注册成临时的全局快捷键，这时按空格不会传给当前的 App；
/// 鼠标一离开卡片就还回去，平时打字完全不受影响。不需要辅助功能权限。
/// 预览窗口要成为焦点窗口才能接收 Esc、方向键，所以打开时把 Velos 切到前台，关上后把焦点还给原来的 App。
@MainActor
final class ClotheslineQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ClotheslineQuickLook()

    /// 按住超过这么久再松开 = 按住看；更短 = 点按（预览一直开着）
    static let holdThreshold: TimeInterval = 0.3

    private var urls: [URL] = []
    /// 和 urls 一一对应：用来找卡片在屏幕上的位置和它的缩略图
    private var entries: [ScreenshotHistory.Entry] = []
    /// 卡片在屏幕上的位置（由晾衣绳提供）：预览从这张卡片放大出来，关上时缩回到这里，和访达里一样
    var cardFrame: ((ScreenshotHistory.Entry) -> CGRect?)?
    /// 卡片上的缩略图：放大、缩回的动画里显示它
    var cardImage: ((ScreenshotHistory.Entry) -> NSImage?)?
    /// 鼠标停在哪张卡片上：按空格就看这张（绳上的全部截图，← → 可以翻）
    private var hovered: (entries: [ScreenshotHistory.Entry], index: Int)?
    private var spaceKey: UInt32?
    /// 这次按下空格打开预览的时刻（按住看：松开时关）；nil 表示这次按下不是打开
    private var openedAt: Date?
    private var spaceDown = false
    /// 打开预览前在前台的 App：关上后把焦点还回去
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    // MARK: - 空格借还

    /// 鼠标停到了卡片上（nil 表示不在任何卡片上）：在卡片上或预览开着时借用空格，否则还回去
    func pointerOver(_ entries: [ScreenshotHistory.Entry], index: Int?) {
        if let index, entries.indices.contains(index) {
            hovered = (entries, index)
        } else {
            hovered = nil
        }
        updateSpaceKey()
    }

    /// 绳子收起：不再有卡片可看（预览开着时空格留着，用来关预览）
    func lineHidden() {
        hovered = nil
        updateSpaceKey()
    }

    private func updateSpaceKey() {
        let wanted = hovered != nil || isOpen
        if wanted, spaceKey == nil {
            spaceKey = HotkeyManager.shared.addTemporary(keyCode: kVK_Space, onRelease: { [weak self] in self?.spaceReleased() }) {
                [weak self] in self?.spacePressed()
            }
        } else if !wanted, let number = spaceKey {
            HotkeyManager.shared.removeTemporary(number)
            spaceKey = nil
            spaceDown = false
        }
    }

    private func spacePressed() {
        guard !spaceDown else { return }   // 按住不放的重复不算
        spaceDown = true
        if isOpen {
            // 预览开着（之前点按打开的）：这一下是关
            openedAt = nil
            close()
        } else if let hovered {
            openedAt = Date()
            show(hovered.entries, at: hovered.index)
        }
    }

    private func spaceReleased() {
        spaceDown = false
        defer { openedAt = nil }
        // 按住看：按了一会儿才松开 → 关；很快就松开 → 点按，预览一直开着
        if let openedAt, Date().timeIntervalSince(openedAt) >= Self.holdThreshold, isOpen {
            close()
        }
    }

    // MARK: - 预览窗口

    /// 打开预览。文件用拖拽用的副本（文件名是「截图 2026-11-14 14.03.01.png」，预览标题好看）
    func show(_ entries: [ScreenshotHistory.Entry], at index: Int) {
        let urls = entries.compactMap { ScreenshotHistory.shared.sharingFile(for: $0) }
        guard urls.count == entries.count, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.entries = entries
        editedBaseline = Dictionary(uniqueKeysWithValues: urls.map { ($0, Self.modificationDate($0)) })
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
        }
        // 快速查看按响应链找谁来提供内容；Velos 没有焦点窗口时问到 AppDelegate，它转给这里
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        updateSpaceKey()
        Log.capture.notice("晾衣绳：快速查看第 \(index + 1) 张")
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        // close（而不是 orderOut）：系统会播放缩回到卡片的动画
        QLPreviewPanel.shared().close()
        didClose()
    }

    /// 预览关上了（空格、Esc、点关闭按钮）：焦点还给原来的 App，空格按需还回去
    private func didClose() {
        saveEdits()
        // 看完：绳子先别收，等鼠标回来
        ClotheslineController.shared.holdUntilPointerReturnsToLine()
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
        updateSpaceKey()
    }

    // MARK: - 标记、旋转后的保存

    /// 打开预览时各个文件的修改时间：关上时比一比，改过的（标记、旋转后系统直接存回这个文件）写回「最近截图」
    private var editedBaseline: [URL: Date?] = [:]

    private func saveEdits() {
        for (index, url) in urls.enumerated() where entries.indices.contains(index) {
            guard let before = editedBaseline[url], Self.modificationDate(url) != before else { continue }
            ScreenshotHistory.shared.replace(entries[index], withContentsOf: url)
        }
        editedBaseline = Dictionary(uniqueKeysWithValues: urls.map { ($0, Self.modificationDate($0)) })
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - 响应链（AppDelegate 转过来）

    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func release(_ panel: QLPreviewPanel) {
        saveEdits()
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
        entries = []
        editedBaseline = [:]
        // Esc、关闭按钮关上的
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOpen else { return }
            self.didClose()
        }
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    // MARK: QLPreviewPanelDelegate

    /// 打开时从这张卡片放大出来、关上时缩回这里（返回 .zero 就是系统默认的淡入淡出）
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated { entry(for: item).flatMap { cardFrame?($0) } ?? .zero }
    }

    /// 放大、缩回的动画里显示卡片上的缩略图
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated { entry(for: item).flatMap { cardImage?($0) } }
    }

    /// 允许「向左旋转」「标记」，和访达里一样。
    /// 注意：这是快速查看未公开的委托方法（公开的头文件里没有，访达用的就是它）。
    /// 以后系统改了名字，最坏情况是这两个按钮不再出现，其他照常
    @objc(previewPanel:canEditItem:)
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, canEditItem item: QLPreviewItem!) -> Bool { true }

    private func entry(for item: QLPreviewItem?) -> ScreenshotHistory.Entry? {
        guard let url = item?.previewItemURL, let index = urls.firstIndex(of: url), entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    /// ← → 看绳上前一张、后一张
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let panel else { return false }
        let step: Int
        switch Int(event.keyCode) {
        case kVK_LeftArrow: step = -1
        case kVK_RightArrow: step = 1
        default: return false
        }
        return MainActor.assumeIsolated {
            let next = panel.currentPreviewItemIndex + step
            if urls.indices.contains(next) { panel.currentPreviewItemIndex = next }
            return true
        }
    }

    #if DEBUG
    var debugHasSpaceKey: Bool { spaceKey != nil }
    func debugSpace(down: Bool) { if down { spacePressed() } else { spaceReleased() } }
    #endif
}
