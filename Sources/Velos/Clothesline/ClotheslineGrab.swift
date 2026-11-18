// 卡片上的鼠标操作移植自 Tendedero（https://github.com/alejandrobujan/tendedero）的 GrabArea
// 和它的修改分支 Picline（https://github.com/Xinguangcuican/Picline）的共享、打开、⇧ 连选。
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 改动：去掉了长按标记、力度触控、拿在手上；拖到别处放下就从绳上拿走；菜单换成 Velos 的操作。

import AppKit
import SwiftUI

/// 每张照片接 AppKit 的拖放，拖进任何 App 都是真正的文件：
/// - 鼠标停在卡片上出现按钮：左上 ✕ 取下，右上 钉在绳上，右下 复制、钉图（钉到屏幕上）
/// - ⌘ 单击：加选 / 取消一张；⇧ 单击：从上次选的那张一路选到这张；单纯单击只是清掉选中（不复制）
/// - 鼠标停在卡片上按空格：快速查看（按住看、松开关；点按一直开着，再点按关上）
/// - 拖进 App、访达、桌面：放下了，它就从绳上走了、挂在那边；没地方接收就飞回绳上。选中几张时一起拖走
/// - 拖到废纸篓、点左上角 ✕：取下
/// - 右键：复制、快速查看、打开、共享、保存到文件、钉在绳上、钉到屏幕、在访达中显示、取下
struct ClotheslineGrabArea: NSViewRepresentable {
    let item: ClotheslineItem
    let model: ClotheslineModel
    /// 存过文件了没有：直接作为参数传进来，存好的那一刻 SwiftUI 才会重新配置点击层
    /// （只看 item、model 的话它以为没变，画出来的按钮换了，点击层还是旧的，点了没反应）
    let saved: Bool

    func makeNSView(context: Context) -> ClotheslineGrabView {
        let view = ClotheslineGrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClotheslineGrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ClotheslineGrabView) {
        let id = item.id
        let model = model
        view.dragImage = item.thumb
        view.toolTip = "空格快速查看 · 拖进其他 App · ⌘ 单击多选"
        view.onSelect = { extending in model.select(id, extending: extending, toggling: !extending) }
        // 按在选中的照片上：保留选中，好一起拖走；单纯点一下松开时才清掉
        view.onPlainPress = { if !model.selectedIDs.contains(id) { model.clearSelection() } }
        view.onPlainClick = { model.clearSelection() }
        view.shownButtons = CardButton.shown(for: item, saved: saved)
        view.onButton = { button in
            switch button {
            case .remove: model.remove(id)
            case .pinOnLine: model.setPinnedOnLine(id, !(model.items.first { $0.id == id }?.pinned ?? false))
            case .copy: model.copy(id)
            case .saveFile: model.save(id)
            case .openFile: model.reveal(id)
            case .exportGIF: model.exportGIF(id)
            case .trash: model.trashOriginal(id)
            }
        }
        view.onDragStart = { model.draggingID = id }
        view.onDragEnd = {
            model.draggingID = nil
            // 拖完一张：绳子先别收，等鼠标回来接着拖
            ClotheslineController.shared.holdUntilPointerReturnsToLine()
        }
        view.dragFiles = { model.dragFiles(id) }
        view.onMovedAway = { ids in model.movedAway(ids) }
        view.shareFiles = { model.shareFiles(id) }
        view.onTrash = { model.remove(id) }
        view.onPressChange = { pressed in model.pressedID = pressed ? id : nil }
        // 弱引用自己：菜单的闭包挂在这个视图上，强引用会互相拉着，卡片取下后视图也释放不掉
        view.menuProvider = { [weak view] in
            let targets = model.targets(id)
            let count = targets.count
            let menu = NSMenu()
            menu.autoenablesItems = false
            if count > 1 {
                let header = NSMenuItem(title: "已选中 \(count) 张", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(.separator())
            }
            let anyRecording = targets.contains(where: \.isLinked)
            // 存在电脑上的（截图存过文件；录屏、GIF 本来就是）
            let savedCount = targets.filter { model.savedIDs.contains($0.id) }.count
            menu.addItem(ClosureMenuItem("复制") { model.copy(id) })
            if count == 1 {
                menu.addItem(ClosureMenuItem("快速查看（空格）") { model.quickLook(id) })
            }
            menu.addItem(ClosureMenuItem("打开") { model.open(id) })
            let share = ClosureMenuItem("共享…") { view?.showSharePicker() }
            share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(share)
            menu.addItem(.separator())
            if !anyRecording {
                if savedCount < count { menu.addItem(ClosureMenuItem("保存到文件") { model.save(id) }) }
                menu.addItem(ClosureMenuItem("钉到屏幕") { model.pinToScreen(id) })
            }
            let allPinned = targets.allSatisfy(\.pinned)
            menu.addItem(ClosureMenuItem(allPinned ? "取消钉在绳上" : "钉在绳上（不会被挤掉）") {
                model.setPinnedOnLine(id, !allPinned)
            })
            // 只有真的存在电脑上的才能在访达里找到：截图要先「存文件」（或截图时就设置了存文件），录屏、GIF 本来就是文件
            if savedCount > 0 {
                menu.addItem(ClosureMenuItem("在访达中显示") { model.reveal(id) })
            }
            menu.addItem(.separator())
            if count == 1, targets.first?.isRecording == true {
                menu.addItem(ClosureMenuItem("导出为 GIF") { model.exportGIF(id) })
            }
            menu.addItem(ClosureMenuItem(count > 1 ? "取下这 \(count) 张" : "取下") { model.remove(id) })
            if savedCount > 0 {
                // 「取下」不删存好的文件，这一项才把文件本身删掉（录屏、GIF 本身；截图存在截图文件夹的那张）
                menu.addItem(ClosureMenuItem(savedCount == count ? RecordingFiles.actionTitle : "把其中存好的文件" + RecordingFiles.actionTitle) {
                    model.trashOriginal(id)
                })
            }
            menu.addItem(ClosureMenuItem("全部取下") { model.removeAll() })
            if ClotheslineUndo.shared.canUndo {
                menu.addItem(ClosureMenuItem("撤销取下（⌘Z）") { ClotheslineUndo.shared.undo() })
            }
            return menu
        }
    }
}

final class ClotheslineGrabView: NSView, NSDraggingSource, NSSharingServicePickerDelegate {
    static var isDragging = false
    /// 照片的右键菜单开着：菜单会伸到绳子外面，绳子先别收起
    static var isShowingMenu = false

    var dragImage: NSImage?
    var dragFiles: () -> [(id: URL, file: URL, thumb: NSImage)] = { [] }
    /// 拖到别处放下了：这几张从绳上拿走
    var onMovedAway: ([URL]) -> Void = { _ in }
    var shareFiles: () -> [URL] = { [] }
    /// 参数：是不是 ⇧（连选）；否则是 ⌘（加选 / 取消一张）
    var onSelect: (Bool) -> Void = { _ in }
    var onPlainPress: () -> Void = {}
    var onPlainClick: () -> Void = {}
    /// 点了卡片上的哪个按钮
    var onButton: (CardButton) -> Void = { _ in }
    /// 这张卡片上有哪些按钮（见 CardButton.shown）
    var shownButtons: [CardButton] = CardButton.allCases {
        didSet { if shownButtons != oldValue { needsLayout = true } }   // 按钮换了：重新放悬停提示
    }
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var pressedButton: CardButton?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 鼠标按在哪个按钮上（按钮画在 SwiftUI 的卡片上，点击由这里按同样的位置判断）
    private func button(at event: NSEvent) -> CardButton? {
        let p = convert(event.locationInWindow, from: nil)
        // CardButton 的位置以左上角为原点
        let topLeft = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        return shownButtons.first { $0.hitRect(in: bounds.size).contains(topLeft) }
    }

    /// 按钮上的提示文字（「复制」「钉图」……）
    override func layout() {
        super.layout()
        removeAllToolTips()
        for button in shownButtons {
            let frame = button.frame(in: bounds.size)
            let rect = isFlipped ? frame : CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
            addToolTip(rect, owner: button.help as NSString, userData: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedButton = nil
        let modifiers = event.modifierFlags.intersection([.shift, .command])
        if !modifiers.isEmpty {
            downPoint = nil
            onSelect(modifiers.contains(.shift))
            return
        }
        onPlainPress()
        if let button = button(at: event) {
            downPoint = nil
            pressedButton = button
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        onPressChange(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        let files = dragFiles()
        guard !files.isEmpty else { return }
        startedDrag = true
        onPressChange(false)
        // 几张一起拖：叠成一小摞，每张错开一点
        let base = imageFrame()
        draggedIDs = files.map(\.id)
        let items = files.enumerated().map { n, file in
            let item = NSDraggingItem(pasteboardWriter: file.file as NSURL)
            item.setDraggingFrame(base.offsetBy(dx: CGFloat(n) * 6, dy: CGFloat(-n) * 6), contents: file.thumb)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        if items.count > 1 { session.draggingFormation = .pile }
        // 松手的地方不接收：飞回绳上
        session.animatesToStartingPositionsOnCancelOrFail = true
        Self.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        onPressChange(false)
        if let pressed = pressedButton {
            pressedButton = nil
            downPoint = nil
            if button(at: event) == pressed { onButton(pressed) }
            return
        }
        // 单纯单击：只清掉选中（复制用右下角的按钮）
        if downPoint != nil && !startedDrag {
            onPlainClick()
        }
        downPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onPressChange(false)
        Self.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        Self.isShowingMenu = false
        // 用完右键菜单：绳子先别收，等鼠标回来
        ClotheslineController.shared.holdUntilPointerReturnsToLine()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 拖进 App、访达都给一份文件（之后从绳上拿走）；delete 让程序坞的废纸篓能接收
        context == .outsideApplication ? [.copy, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.isDragging = false
        startedDrag = false
        downPoint = nil
        onDragEnd()
        let ids = draggedIDs
        draggedIDs = []
        if operation.contains(.delete) {
            // 拖到了废纸篓：系统只告诉我们，由我们取下（原图进废纸篓）
            onTrash()
        } else if !operation.isEmpty {
            // 放下了（聊天窗口、访达、桌面……）：从绳上走了，挂在那边（缩小淡出的动画由绳子播放）
            onMovedAway(ids)
        }
        // operation 为空：没地方接收，系统已经让它飞回绳上
    }

    /// 这次拖的是哪几张
    private var draggedIDs: [URL] = []

    // MARK: 共享

    /// 右键「共享…」：系统的共享菜单（隔空投送、信息、邮件……），选中几张就一起
    func showSharePicker() {
        let files = shareFiles()
        guard !files.isEmpty else { return }
        // 菜单关掉之后再弹（菜单还在跑自己的事件循环时弹不出来）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            // 共享窗口是普通窗口，Velos 要到前台它才会出现在最前面
            NSApp.activate()
            let picker = NSSharingServicePicker(items: files)
            picker.delegate = self
            // 共享菜单开着时绳子别收起（它挂在这张卡片上）
            Self.isShowingMenu = true
            picker.show(relativeTo: self.bounds, of: self, preferredEdge: .minY)
        }
    }

    /// 选了一种共享方式，或者没选就关了
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        Self.isShowingMenu = false
        ClotheslineController.shared.holdUntilPointerReturnsToLine()
    }

    /// 拖拽时的预览保持照片的长宽比
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

/// 用闭包响应的菜单项
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

/// 卡片上的按钮（鼠标停在卡片上时出现），位置见 frame(in:)
enum CardButton: CaseIterable {
    case remove, pinOnLine, copy, saveFile, openFile, exportGIF, trash

    /// 这张卡片上有哪些：截图有存文件，录屏有 GIF 和删除，GIF 有删除。
    /// 钉图不放按钮（截图时工具栏上就能直接钉图），右键菜单里还有「钉到屏幕」
    /// 录屏、GIF 本来就是存好的文件，所以没有「存文件」
    /// - Parameter saved: 已经存成文件了（截图存过；录屏、GIF 本来就是）：左下角换成删除，复制前面多一个「打开文件位置」
    @MainActor
    static func shown(for item: ClotheslineItem, saved: Bool) -> [CardButton] {
        allCases.filter { button in
            switch button {
            case .saveFile: !item.isLinked && !saved
            case .openFile: saved
            case .exportGIF: item.isRecording
            case .trash: saved
            default: true
            }
        }
    }

    static let size: CGFloat = 26
    static let inset: CGFloat = 4
    static let gap: CGFloat = 5

    var symbol: String {
        switch self {
        case .remove: "xmark"
        case .pinOnLine: "hanger"
        case .copy: "doc.on.doc"
        case .saveFile: "square.and.arrow.down"
        case .openFile: "folder"
        case .exportGIF: "GIF"   // 画成文字（见 ClotheslineViews）
        case .trash: "trash"
        }
    }

    @MainActor var help: String {
        switch self {
        case .remove: "取下"
        case .pinOnLine: "钉在绳上（不会被挤掉）"
        case .copy: "复制"
        case .saveFile: "存文件（存到截图文件夹）"
        case .openFile: "打开文件位置（在访达中显示）"
        case .exportGIF: "导出为 GIF（存在录屏旁边，也挂到绳上）"
        case .trash: RecordingFiles.deletesForever ? "永久删除（不进废纸篓，没法找回）" : "删除（文件本身移到废纸篓，能放回来）"
        }
    }

    /// 按钮在卡片里的位置（左上角为原点）。
    /// 截图：左上 ✕；右上 衣架；右下 复制；左下 存文件。存好后：左下换成删除，复制前面多一个打开文件位置。
    /// 录屏：左上 ✕；右上 衣架；右下 GIF、打开文件位置、复制（复制在最右）；左下 删除。GIF：同录屏，没有 GIF 按钮
    func frame(in card: CGSize) -> CGRect {
        let s = Self.size, i = Self.inset
        let right = card.width - i - s, secondFromRight = card.width - i - s * 2 - Self.gap
        let thirdFromRight = card.width - i - s * 3 - Self.gap * 2
        let bottom = card.height - i - s
        switch self {
        case .remove: return CGRect(x: i, y: i, width: s, height: s)
        case .pinOnLine: return CGRect(x: right, y: i, width: s, height: s)
        case .copy: return CGRect(x: right, y: bottom, width: s, height: s)
        case .openFile: return CGRect(x: secondFromRight, y: bottom, width: s, height: s)
        case .exportGIF: return CGRect(x: thirdFromRight, y: bottom, width: s, height: s)
        case .trash, .saveFile: return CGRect(x: i, y: bottom, width: s, height: s)   // 两个不会同时出现
        }
    }

    /// 点击范围比按钮大一圈，好点
    func hitRect(in card: CGSize) -> CGRect { frame(in: card).insetBy(dx: -3, dy: -3) }
}
