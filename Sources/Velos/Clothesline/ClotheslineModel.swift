// 晾衣绳的设计和部分代码移植自 Tendedero（https://github.com/alejandrobujan/tendedero）和它的修改分支
// Picline（https://github.com/Xinguangcuican/Picline）的 Line：多选（⇧ 连选、⌘ 加选）、保留数量与滚动、钉住、打开。
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 这里改成以 Velos 的「最近截图」为数据，界面换成 Velos 的样子。

import AppKit
import Combine

/// 绳上挂的一张截图（或一段录屏）
struct ClotheslineItem: Identifiable, Equatable {
    let entry: ScreenshotHistory.Entry
    let thumb: NSImage
    /// 每张照片都挂得有点歪，像真的晾衣绳（按文件名固定，重新读取时不会乱晃）
    let tilt: Double

    var id: URL { entry.url }
    var pinned: Bool { entry.pinned }
    var isRecording: Bool { entry.isRecording }
    var isGIF: Bool { entry.isGIF }
    /// 录屏、GIF：存的是替身，没法钉到屏幕
    var isLinked: Bool { entry.isLinked }

    static func == (a: ClotheslineItem, b: ClotheslineItem) -> Bool {
        a.id == b.id && a.thumb === b.thumb && a.pinned == b.pinned
    }
}

/// 照片挂多大（设置里选，默认中）
enum ClotheslineSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: Self { self }
    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1
        case .large: 1.35
        }
    }
}

/// 晾衣绳上挂了什么、每张能做什么。
/// 数据就是「最近截图」：钉住的挂在最左边，其余最新的在右边。只在绳子放下来时读缩略图，收起后释放。
/// 绳子保留多少张：能放下几张就几张，或者设置里选的 25 / 50 / 100 张（多出来的往左滚动着看）
@MainActor
final class ClotheslineModel: ObservableObject {
    @Published private(set) var items: [ClotheslineItem] = []
    @Published private(set) var doneIDs: Set<URL> = []
    /// 真的存在电脑上的（截图存过文件；录屏、GIF 本来就是文件）：左下角是删除，复制前面是「打开文件位置」
    @Published private(set) var savedIDs: Set<URL> = []
    /// 刚做完的事在卡片下面显示的小标签（「已复制」「已存好」）
    private(set) var doneText = "已复制"
    /// 选中的：⌘ 单击加选 / 取消一张，⇧ 单击从上次选的那张一路选到这张
    @Published private(set) var selectedIDs: Set<URL> = []
    @Published var draggingID: URL?
    @Published var pressedID: URL?
    /// 绳子已经从菜单栏下面滑下来
    @Published var revealed = false
    /// 一阵风：绳子放下来时照片轻轻晃一下
    @Published private(set) var gust = 0
    /// 拖着图片到了绳子上：显示「松手挂到这里」
    @Published var catching = false
    /// 正在从截图位置飞过来的那张：真卡片先藏着，飞到了再出现
    @Published var flyingID: URL?
    /// 第一次使用：绳子自己放下来，写一句怎么用（这时的提示文字）
    @Published var coachingText: String?
    /// 往左滚了多远（点）：0 是最新的那头；保留数量多于屏幕放得下时才能滚
    @Published var scroll: CGFloat = 0
    /// 正在导出 GIF 的录屏和进度（0~1），卡片上显示「正在生成 GIF 42%」
    @Published private(set) var gifProgress: [URL: Double] = [:]
    private var gifTasks: [URL: Task<Void, Never>] = [:]

    /// 各张卡片的位置（窗口坐标，左上角为原点），由视图上报。面板只在鼠标在卡片上时接收点击，其余地方点击穿透
    var hitRects: [URL: CGRect] = [:]
    /// 屏幕上一次放得下几张
    var visibleCount = 8
    /// 绳上最多挂几张（不算钉住的）：能放下几张就几张，或设置里选的数量
    var maxItems = 8

    /// ⇧ 连选从哪张量起：上一次单独选上的那张
    private var anchorID: URL?
    private var copyGeneration = 0

    // MARK: - 读取

    /// 从「最近截图」重新读：钉住的在最左边（按钉上的先后），其余最新的在右边。已经读过的缩略图直接沿用
    func reload() {
        let all = ScreenshotHistory.entries()
        let order = ScreenshotHistory.pinnedOrder()
        let pinned = all.filter(\.pinned).sorted {
            (order.firstIndex(of: $0.url.lastPathComponent) ?? 0) < (order.firstIndex(of: $1.url.lastPathComponent) ?? 0)
        }
        let loose = Array(all.filter { !$0.pinned }.prefix(maxItems).reversed())
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = (pinned + loose).compactMap { entry in
            if let old = known[entry.url], old.pinned == entry.pinned { return old }
            guard let thumb = NSImage(contentsOf: entry.thumbnailURL) ?? ScreenshotHistory.shared.image(for: entry)
                .map({ NSImage(cgImage: $0, size: .zero) }) else { return nil }
            return ClotheslineItem(entry: entry, thumb: thumb, tilt: Self.tilt(for: entry.url))
        }
        selectedIDs.formIntersection(items.map(\.id))
        refreshSaved(watch: false)   // 读一遍是因为「最近截图」变了：控制器那边已经换过要看的文件夹
        scroll = min(scroll, maxScroll)
    }

    /// 重新看哪些存过文件
    /// - Parameter watch: 顺便让控制器看着新存的文件所在的文件夹（「存文件」之后）
    private func refreshSaved(watch: Bool = true) {
        let saved = Set(ScreenshotHistory.shared.savedFiles(for: items.map(\.entry)).keys)
        if saved != savedIDs { savedIDs = saved }
        if watch { ClotheslineController.shared.refreshFileWatch() }
    }

    /// 这一张的图改过了：下次 reload 重新读它的缩略图
    func forget(_ url: URL) {
        items.removeAll { $0.id == url }
    }

    /// 收起后不再占着缩略图
    func unload() {
        items = []
        hitRects = [:]
        selectedIDs = []
        doneIDs = []
        anchorID = nil
        scroll = 0
    }

    var isEmpty: Bool { items.isEmpty }
    /// 最左边钉住的有几张
    var pinnedLead: Int { items.prefix { $0.pinned }.count }

    /// -2.5° ~ 2.5°，由文件名决定
    private static func tilt(for url: URL) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in url.lastPathComponent.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Double(hash % 1000) / 1000 * 5 - 2.5
    }

    /// 一阵风：卡片轻轻晃一下
    func breeze() { gust += 1 }

    // MARK: - 滚动（保留数量多于屏幕放得下时）

    private var maxScroll: CGFloat {
        CGFloat(max(0, items.count - visibleCount)) * ClotheslineLayout.spacing
    }

    /// 双指左右滑、鼠标滚轮：往左看更早的
    func scroll(by delta: CGFloat) {
        let next = min(maxScroll, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    // MARK: - 选择（移植自 Picline 的 Line.select）

    var selectedItems: [ClotheslineItem] { items.filter { selectedIDs.contains($0.id) } }

    /// ⌘ 单击：加选 / 取消这一张；⇧ 单击：从上次选的那张一路选到这张（两头都算）
    func select(_ id: URL, extending: Bool, toggling: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if extending, let anchor = anchorID, let from = items.firstIndex(where: { $0.id == anchor }) {
            let run = from <= index ? from...index : index...from
            selectedIDs = Set(items[run].map(\.id))
            return
        }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        anchorID = id
    }

    func clearSelection() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    /// 这次操作的对象：在选中的几张里就是选中的全部，否则只是这一张
    func targets(_ id: URL) -> [ClotheslineItem] {
        if selectedIDs.contains(id), selectedIDs.count > 1 { return selectedItems }
        return items.filter { $0.id == id }
    }

    // MARK: - 操作

    /// 单击：复制。一张图片复制成图片（无损 PNG），录屏或几张时复制成文件（聊天软件里粘贴就是这几个）
    func copy(_ id: URL) {
        let photos = targets(id)
        guard !photos.isEmpty else { return }
        if photos.count == 1 {
            ScreenshotHistory.shared.copy(photos[0].entry)
        } else {
            let urls = photos.compactMap { ScreenshotHistory.shared.sharingFile(for: $0.entry) }
            let pasteboard = Self.pasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString("1", forType: ClipboardWatcher.ownType)
                return item
            })
            Log.capture.notice("晾衣绳：复制了 \(urls.count) 张")
        }
        showDone("已复制", on: photos)
    }

    /// 卡片下面冒出一个小标签（1.2 秒后消失），卡片轻轻晃一下
    private func showDone(_ text: String, on photos: [ClotheslineItem]) {
        doneText = text
        copyGeneration += 1
        let generation = copyGeneration
        doneIDs = []
        doneIDs = Set(photos.map(\.id))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copyGeneration == generation { self?.doneIDs = [] }
        }
    }

    /// 右键「快速查看」：用系统的快速查看打开，一直开着（再按空格或 Esc 关上）
    func quickLook(_ id: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        ClotheslineQuickLook.shared.show(items.map(\.entry), at: index)
    }

    /// 右键「打开」：用默认的 App 打开（图片一般是「预览」），选中几张就一起打开
    func open(_ id: URL) {
        let urls = targets(id).compactMap { ScreenshotHistory.shared.sharingFile(for: $0.entry) }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// 共享 / 隔空投送的文件（选中几张就几张）
    func shareFiles(_ id: URL) -> [URL] {
        targets(id).compactMap { ScreenshotHistory.shared.sharingFile(for: $0.entry) }
    }

    /// 录屏导出 GIF（原来录屏缩略图上的「GIF」）：卡片上显示进度，GIF 存在录屏旁边，做好后也挂到绳上
    func exportGIF(_ id: URL) {
        guard let item = items.first(where: { $0.id == id }), item.isRecording, gifTasks[id] == nil else { return }
        let video = item.entry.fileURL
        let prefs = Preferences.shared
        let options = GIFExporter.Options(fps: prefs.gifFrameRate.rawValue, maxWidth: prefs.gifMaxWidth.rawValue)
        gifProgress[id] = 0
        gifTasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.gifProgress[id] = nil
                self?.gifTasks[id] = nil
            }
            do {
                let gif = try await GIFExporter.export(video: video, options: options) { fraction in
                    // 进度从后台线程报上来：交给主线程上的晾衣绳更新卡片
                    Task { @MainActor in ClotheslineController.shared.gifProgressChanged(id, fraction) }
                }
                Log.capture.notice("晾衣绳：GIF 已导出 \(gif.lastPathComponent, privacy: .public)")
                ScreenshotHistory.shared.recordLinked(gif)
            } catch is CancellationError {
                Log.capture.notice("晾衣绳：GIF 导出已取消")
            } catch {
                Log.capture.error("晾衣绳：GIF 导出失败 \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// 导出 GIF 的进度（还在导出时才更新）
    func updateGIFProgress(_ id: URL, _ fraction: Double) {
        if gifProgress[id] != nil { gifProgress[id] = fraction }
    }

    /// 删除录屏、GIF 本身（按设置放进废纸篓或永久删除）
    func trashOriginal(_ id: URL) {
        let photos = targets(id).filter { savedIDs.contains($0.id) }
        guard !photos.isEmpty else { return }
        for photo in photos { gifTasks[photo.id]?.cancel() }
        take(photos)
        ScreenshotHistory.shared.deleteOriginals(photos.map(\.entry))
    }

    /// 保存到截图文件夹（按设置的格式），原来缩略图上的「保存」
    func save(_ id: URL) {
        let photos = targets(id).filter { !$0.isLinked }
        for item in photos {
            guard let capture = capture(of: item) else { continue }
            // 存好后，这张的「存文件」按钮换成删除，复制前面多一个「打开文件位置」
            ScreenshotOutput.save(capture) { [weak self] _ in self?.refreshSaved() }
        }
        if !photos.isEmpty { showDone("已存好", on: photos) }
    }

    /// 钉到屏幕上（钉图窗口）
    func pinToScreen(_ id: URL) {
        for item in targets(id) { ScreenshotHistory.shared.pin(item.entry) }
    }

    /// 钉在绳上：挂到最左边，新截图再多也不会把它挤掉；再点一次取消
    func setPinnedOnLine(_ id: URL, _ pinned: Bool) {
        ScreenshotHistory.shared.setPinned(targets(id).map(\.entry), pinned)
    }

    func reveal(_ id: URL) {
        let urls = targets(id).compactMap { ScreenshotHistory.shared.savedFile(for: $0.entry) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// 取下（点 ✕、拖到废纸篓、右键「取下」）：原图移到废纸篓
    func remove(_ id: URL) {
        let photos = targets(id)
        take(photos)
        // 先暂存（⌘Z 能放回来），过一阵再进废纸篓
        ClotheslineUndo.shared.takeDown(photos.map(\.entry), disposal: .trash)
    }

    /// 拖到别处放下了（聊天窗口、访达、桌面……）：它从绳上走了，挂在那边。
    /// 拖出去的是副本，「最近截图」里这张直接删掉（不进废纸篓）
    func movedAway(_ ids: [URL]) {
        let photos = items.filter { ids.contains($0.id) }
        guard !photos.isEmpty else { return }
        take(photos)
        ClotheslineUndo.shared.takeDown(photos.map(\.entry), disposal: .delete)
        Log.capture.notice("晾衣绳：拖走了 \(photos.count) 张")
    }

    func removeAll() {
        let all = items
        take(all)
        ClotheslineUndo.shared.takeDown(all.map(\.entry), disposal: .trash)
    }

    /// 从绳上拿下来（带动画，由视图的 transition 播放）
    private func take(_ photos: [ClotheslineItem]) {
        let ids = Set(photos.map(\.id))
        for id in ids { gifTasks[id]?.cancel() }
        selectedIDs.subtract(ids)
        if let anchorID, ids.contains(anchorID) { self.anchorID = nil }
        items.removeAll { ids.contains($0.id) }
    }

    /// 拖出去的文件：一张或选中的几张（和它们的 id，拖成功后从绳上拿下）
    func dragFiles(_ id: URL) -> [(id: URL, file: URL, thumb: NSImage)] {
        targets(id).compactMap { item in
            ScreenshotHistory.shared.sharingFile(for: item.entry).map { (item.id, $0, item.thumb) }
        }
    }

    private func capture(of item: ClotheslineItem) -> CapturedImage? {
        ScreenshotHistory.shared.capture(of: item.entry)
    }

    private static var pasteboard: NSPasteboard {
        #if DEBUG
        if ScreenshotOutput.dryRun { return NSPasteboard(name: .init("local.velos.selftest")) }
        #endif
        return .general
    }
}
