// 撤销取下的思路来自 Tendedero（https://github.com/alejandrobujan/tendedero）的 ⌘Z「Put back」，
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 改动：取下的文件先放进「最近截图」里的暂存文件夹，撤销时搬回来；按 Velos 的结构重写。

import AppKit
import Carbon.HIToolbox

/// 晾衣绳上的 ⌘Z：把刚取下（点 ✕、右键取下、拖到废纸篓、全部取下）或拖走的那张（那一组）放回来。
///
/// - 取下的文件不马上进废纸篓，先搬进 History/.undo/<这一步>/ 暂存；⌘Z 时原样搬回来（钉住的照样钉住）
/// - 最多记 10 步；更早的那一步、以及 Velos 退出时，暂存的文件按原来的意思处理：
///   取下的截图进废纸篓（还能从废纸篓放回来），拖走的（那边已经有一份了）直接删掉；录屏、GIF 只是替身，删掉替身
/// - ⌘Z 只在鼠标停在绳子上、而且有能撤销的时候才借用（临时的全局快捷键），鼠标离开就还给当前的 App
@MainActor
final class ClotheslineUndo {
    static let shared = ClotheslineUndo()

    /// 暂存的文件最后怎么处理
    enum Disposal: String, Codable {
        /// 截图进废纸篓（录屏、GIF 只删替身）
        case trash
        /// 直接删掉（拖到别处去了，那边已经有一份）
        case delete
    }

    private struct Step: Codable {
        let id: UUID
        /// 文件名、当时是不是钉住的
        let names: [String]
        let pinned: [String]
        let disposal: Disposal
    }

    private var steps: [Step] = []
    private static let limit = 10
    private var undoKey: UInt32?

    private init() {}

    nonisolated static var folder: URL { ScreenshotHistory.directory.appendingPathComponent(".undo", isDirectory: true) }

    var canUndo: Bool { !steps.isEmpty }

    // MARK: - 取下

    /// 从绳上拿下来：文件先暂存，能用 ⌘Z 放回来
    func takeDown(_ entries: [ScreenshotHistory.Entry], disposal: Disposal) {
        guard !entries.isEmpty else { return }
        let step = Step(id: UUID(), names: entries.map(\.url.lastPathComponent),
                        pinned: entries.filter(\.pinned).map(\.url.lastPathComponent), disposal: disposal)
        let stepFolder = Self.folder.appendingPathComponent(step.id.uuidString, isDirectory: true)
        let manager = FileManager.default
        try? manager.createDirectory(at: stepFolder, withIntermediateDirectories: true)
        if !step.pinned.isEmpty { ScreenshotHistory.shared.setPinned(entries.filter(\.pinned), false, prunes: false) }
        for entry in entries {
            try? manager.moveItem(at: entry.url, to: stepFolder.appendingPathComponent(entry.url.lastPathComponent))
            try? manager.moveItem(at: entry.thumbnailURL, to: stepFolder.appendingPathComponent(entry.thumbnailURL.lastPathComponent))
        }
        steps.append(step)
        while steps.count > Self.limit { finalize(steps.removeFirst()) }
        ScreenshotHistory.notifyChanged()
        updateKey()
    }

    // MARK: - 撤销

    /// 把最近取下的那一步放回来
    func undo() {
        guard let step = steps.popLast() else { return NSSound.beep() }
        let stepFolder = Self.folder.appendingPathComponent(step.id.uuidString, isDirectory: true)
        let manager = FileManager.default
        for name in step.names {
            let url = ScreenshotHistory.directory.appendingPathComponent(name)
            try? manager.moveItem(at: stepFolder.appendingPathComponent(name), to: url)
            let thumb = ScreenshotHistory.thumbnailURL(for: url)
            try? manager.moveItem(at: stepFolder.appendingPathComponent(thumb.lastPathComponent), to: thumb)
        }
        try? manager.removeItem(at: stepFolder)
        let restored = ScreenshotHistory.entries().filter { step.pinned.contains($0.url.lastPathComponent) }
        if !restored.isEmpty { ScreenshotHistory.shared.setPinned(restored, true) }
        Log.capture.notice("晾衣绳：撤销取下，放回 \(step.names.count) 张")
        ScreenshotHistory.notifyChanged()
        updateKey()
    }

    // MARK: - 最后的处理

    /// 退出前（和启动时清理上次没处理完的）：所有暂存的按原来的意思处理掉
    func finalizeAll() {
        steps.forEach(finalize)
        steps.removeAll()
        // 上次异常退出留下的：当作取下的，进废纸篓
        let manager = FileManager.default
        if let leftovers = try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) {
            for folder in leftovers { Self.dispose(folder: folder, disposal: .trash) }
        }
        try? manager.removeItem(at: Self.folder)
        updateKey()
    }

    private func finalize(_ step: Step) {
        Self.dispose(folder: Self.folder.appendingPathComponent(step.id.uuidString, isDirectory: true), disposal: step.disposal)
    }

    private static func dispose(folder: URL, disposal: Disposal) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let ext = file.pathExtension.lowercased()
            // 截图本身：取下的进废纸篓；缩略图、录屏和 GIF 的替身、拖走的：直接删
            if disposal == .trash, ext == "png" {
                if (try? manager.trashItem(at: file, resultingItemURL: nil)) == nil { try? manager.removeItem(at: file) }
            } else {
                try? manager.removeItem(at: file)
            }
        }
        try? manager.removeItem(at: folder)
    }

    // MARK: - ⌘Z（鼠标在绳子上时才借用）

    private var pointerOnLine = false

    func pointerOnLine(_ on: Bool) {
        pointerOnLine = on
        updateKey()
    }

    private func updateKey() {
        let wanted = pointerOnLine && canUndo
        if wanted, undoKey == nil {
            undoKey = HotkeyManager.shared.addTemporary(keyCode: kVK_ANSI_Z, modifiers: UInt32(cmdKey)) {
                ClotheslineUndo.shared.undo()
            }
        } else if !wanted, let key = undoKey {
            HotkeyManager.shared.removeTemporary(key)
            undoKey = nil
        }
    }

    #if DEBUG
    var debugStepCount: Int { steps.count }
    var debugHasUndoKey: Bool { undoKey != nil }
    #endif
}
