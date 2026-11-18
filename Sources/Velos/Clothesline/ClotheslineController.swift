// 晾衣绳的面板和放下 / 收起的规则参考 Tendedero（https://github.com/alejandrobujan/tendedero）的 LinePanel、AppDelegate，
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 最大的改动：Tendedero 每秒查 30 次鼠标位置；这里改成只在鼠标动了时由系统通知（只听的事件分接），鼠标不动时完全不占 CPU。

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 晾衣绳：最近的截图挂在屏幕顶上一根绳子上，平时藏在菜单栏后面。
///
/// 怎么放下来：
/// - 按住 ⌥ 把鼠标移到屏幕最上面（全屏 App 里也行；设置里可以关）
/// - 快捷键（默认 ⌥F）或菜单「晾衣绳」：放下 / 收起
/// - 按住一张图片（访达、浏览器里的）往屏幕顶上拖：绳子下来接，松手就挂上
/// 怎么收起：鼠标离开绳子 1 秒；点绳子外面任何地方（包括菜单栏）；再按一次快捷键。
///
/// 怎么知道鼠标在哪：用「只听的事件分接」（CGEventTap，listenOnly）。系统每次鼠标移动、按下、拖动都抄送一份过来，
/// 不管鼠标在哪个 App、菜单栏还是全屏 App 上；只听不改，不影响任何 App 收到的事件。
/// 鼠标不动时什么都收不到，CPU 为 0。（以前用的 NSEvent 全局监听只在鼠标下的 App 要移动事件时才收得到，
/// 鼠标在菜单栏、很多 App 上时根本不知道，所以「移到上面不灵敏」。）
/// 唯一会定时看一眼的情况：鼠标停在屏幕最上面、还没按 ⌥ 时，接下来几秒里每秒看 10 次 ⌥ 有没有按下（停着不动没有事件）。
/// 收起后面板和缩略图全部释放，空闲内存不变。
@MainActor
final class ClotheslineController {
    static let shared = ClotheslineController()

    private let model = ClotheslineModel()
    private var panel: ClotheslinePanel?
    private(set) var isRevealed = false
    /// 用快捷键或菜单放下来的：鼠标还没进过绳子时不因为「鼠标不在绳子上」收起
    private var openedOnPurpose = false
    private var pointerWasInside = false
    /// 刚在绳上做完一件事（拖走一张、用完右键菜单 / 共享 / 快速查看）：鼠标回到绳子上之前不自动收起，
    /// 好接着拖下一张。点绳子外面、按 ⌥F 照样收起
    private var holdUntilPointerReturns = false
    /// 「最近截图」有几张（只在变化时读一次文件夹）：空绳子不因为鼠标碰顶部而放下来
    private var historyCount = 0

    private var moveMonitors: [Any] = []
    private var clickMonitors: [Any] = []
    /// 只听的事件分接（拿不到时退回 NSEvent 全局监听）
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    /// 鼠标停在屏幕最上面、还没按 ⌥：短时间看 ⌥ 有没有按下
    private var edgeWatch: Timer?
    private var edgeWatchUntil = Date.distantPast
    private var retractTimer: Timer?
    private var releaseTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var historyObserver: NSObjectProtocol?

    /// 鼠标离开多久收起
    static let retractDelay: TimeInterval = 1.0

    private init() {}

    /// 卡片里照片在屏幕上的位置（快速查看从这里放大出来、缩回这里）；绳子收着或这张不在绳上时为 nil
    private func photoFrame(of entry: ScreenshotHistory.Entry) -> CGRect? {
        guard isRevealed, let panel, let box = model.hitRects[entry.url] else { return nil }
        // 卡片挂着是歪的，量到的是把歪卡片框住的那个正框（比卡片本身大一圈）：中心不变，按歪的角度算回卡片本身的大小
        let tilt = (model.items.first { $0.id == entry.url }?.tilt ?? 0) * .pi / 180
        let c = cos(tilt), s = abs(sin(tilt)), d = c * c - s * s
        let size = d > 0.5 ? CGSize(width: (box.width * c - box.height * s) / d, height: (box.height * c - box.width * s) / d) : box.size
        let card = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        // 卡片位置是窗口坐标（左上角为原点），换成屏幕坐标；照片在卡片里四周缩进 CardFrame.inset
        return CGRect(x: panel.frame.minX + card.minX, y: panel.frame.maxY - card.maxY, width: card.width, height: card.height)
            .insetBy(dx: CardFrame.inset, dy: CardFrame.inset)
    }

    func start() {
        // Velos 没开着时在访达里删掉的：悄悄拿掉（开着时删的才放下绳子给你看）
        ScreenshotHistory.shared.pruneDeletedFiles(notify: false)
        ClotheslineQuickLook.shared.cardFrame = { [weak self] entry in self?.photoFrame(of: entry) }
        ClotheslineQuickLook.shared.cardImage = { [weak self] entry in self?.model.items.first { $0.id == entry.url }?.thumb }
        let prefs = Preferences.shared
        Publishers.CombineLatest(prefs.$clotheslineEnabled, prefs.$clotheslineHover)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, _ in
                // @Published 在值改之前发出：等这一轮改完再处理
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !enabled, self.isRevealed { self.hide() }
                    self.updateMonitoring()
                    self.refreshFileWatch()
                }
            }
            .store(in: &observers)
        historyObserver = NotificationCenter.default.addObserver(forName: ScreenshotHistory.didChange, object: nil, queue: .main) { note in
            let changed = note.object as? URL
            MainActor.assumeIsolated {
                // 某一张改过（快速查看里标记、旋转）：它的卡片换成新的缩略图
                if let changed { ClotheslineController.shared.model.forget(changed) }
                ClotheslineController.shared.historyChanged()
            }
        }
        // 照片大小、保留数量改了：重新排一遍（绳子放下来时立刻看到变化）
        Publishers.CombineLatest(prefs.$clotheslineSize, prefs.$clotheslineKeep)
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.layoutChanged() } }
            .store(in: &observers)
        // 接收剪贴板图片（默认关）：开着晾衣绳、保留最近截图、勾了这一项才定时看剪贴板
        Publishers.CombineLatest(prefs.$clotheslineEnabled, prefs.$clotheslineClipboard)
            .removeDuplicates { $0 == $1 }
            .sink { enabled, clipboard in
                DispatchQueue.main.async { ClipboardWatcher.shared.setRunning(enabled && clipboard) }
            }
            .store(in: &observers)
        historyCount = ScreenshotHistory.entries().count
        updateMonitoring()
        watchSpaces()
        showIntroIfNeeded()
    }

    // MARK: - 多个桌面、显示器变化（移植自 Picline）

    private var spaceObservers: [NSObjectProtocol] = []

    private func watchSpaces() {
        let workspace = NSWorkspace.shared.notificationCenter
        // 切换桌面、进出全屏 App：等切换动画放完，要是系统把绳子落在了原来那个桌面上，就在这个桌面上重新做一个
        spaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // 用快捷键放下来的只算在当时那个桌面
                ClotheslineController.shared.openedOnPurpose = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ClotheslineController.shared.keepOnActiveSpace() }
            }
        })
        // 插拔显示器、改分辨率：绳子放下来时重新摆
        spaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                     object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.screensChanged() }
        })
    }

    /// 绳子是所有桌面共用的一个窗口；用久了系统偶尔会把它绑死在某一个桌面上，换到别的桌面就看不见了。
    /// 这时在当前桌面重新做一个窗口，内容原样搬过去
    private func keepOnActiveSpace() {
        guard isRevealed, let old = panel, old.isVisible, !old.isOnActiveSpace else { return }
        Log.capture.notice("晾衣绳：不在当前桌面上，重新做一个窗口")
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = ClotheslinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func screensChanged() {
        guard isRevealed, let panel else { return }
        guard let screen = panel.screen ?? Self.screenUnderPointer() else { return hide() }
        updateCapacity(for: screen)
        panel.place(on: screen)
        model.reload()
    }

    // MARK: - 第一次使用（移植自 Picline 0.3.0：第一次装上绳子自己下来 9 秒，写两行怎么用）

    private static let introKey = "clotheslineIntroShown"

    private func showIntroIfNeeded() {
        guard isEnabled, !AppIdentity.defaults.bool(forKey: Self.introKey) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))   // 等 Velos 启动完
            guard let self, self.isEnabled, !self.isRevealed else { return }
            AppIdentity.defaults.set(true, forKey: Self.introKey)
            let key = ClotheslineModifier.current.symbol
            let hotkey = Preferences.shared.clotheslineHotkey.displayString
            self.model.coachingText = "截图、录屏会挂在这根绳子上\n以后按住 \(key) 把鼠标推到屏幕最上面（或按 \(hotkey)），它就会下来"
            self.reveal(on: Self.screenUnderPointer(), onPurpose: true)
            Log.capture.notice("晾衣绳：第一次使用，放下来介绍一下")
            try? await Task.sleep(for: .seconds(9))
            self.model.coachingText = nil
            // 鼠标没过去就收起；过去了就照常（离开时收起）
            if self.isRevealed, !self.pointerWasInside { self.hide() }
        }
    }

    /// 大小或保留数量改了：重新算一次放得下几张；放下来时换成新大小的面板
    private func layoutChanged() {
        guard isRevealed, let panel, let screen = panel.screen else { return }
        updateCapacity(for: screen)
        panel.place(on: screen)
        model.unload()
        model.reload()
        model.revealed = true
    }

    /// 一次放得下几张，最多挂几张（保留数量设成 25 / 50 / 100 时多出来的滚动着看）
    private func updateCapacity(for screen: NSScreen) {
        let fits = ClotheslineLayout.capacity(width: screen.visibleFrame.width)
        model.visibleCount = fits
        model.maxItems = max(fits, ClotheslineLayout.keep)
    }

    var isEnabled: Bool { Preferences.shared.clotheslineEnabled }

    /// 导出 GIF 的进度（从后台报上来）
    func gifProgressChanged(_ id: URL, _ fraction: Double) { model.updateGIFProgress(id, fraction) }

    /// 绳子放下来时面板的窗口编号：截图、录屏时不排除它（绳子是屏幕上的内容）
    var windowNumber: CGWindowID? {
        guard isRevealed, let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    // MARK: - 截图后挂上去（代替角落的缩略图）

    /// 新截图挂上去以后，绳子放下来给你看多久（鼠标过去了就一直不收，离开后照常收起）
    static let peekDuration: TimeInterval = 2.5
    /// 等着下一张截图写进「最近截图」后放下来，放在哪块屏幕
    private var pendingPeekScreen: NSScreen?
    private var peekUntil = Date.distantPast
    private var peekTimer: Timer?

    /// 截图、录屏完成：在后台写进「最近截图」，写好后绳子放下来，新的一张挂在最右边。
    /// - Parameters:
    ///   - rect: 截图的位置（录屏是录的那块屏幕）
    ///   - image: 截下来的图：马上在原位「咔嚓」一下被拎起来，等绳子放下来后飞到它在绳上的位置
    ///   - flies: 要不要飞（录屏没有现成的图：等第一帧的缩略图写好，再从录的那块区域原位飞）
    func showNextCapture(near rect: CGRect, image: CGImage? = nil, flies: Bool = false) {
        pendingPeekScreen = NSScreen.screen(containing: CGPoint(x: rect.midX, y: rect.midY)) ?? Self.screenUnderPointer()
        guard image != nil || flies else { return }
        if let image, let flight = ClotheslineFlight(image: image, from: rect) {
            // 每一张截图排一个队：连着截好几张时，每张都有自己飞的那一下，不会互相顶掉（以前后一张会把前一张顶掉，前一张就停在屏幕上了）
            waitingFlights.append(flight)
            flight.snap()
            // 等了 4 秒还没写进去（例如写文件失败）：这一张原地淡掉
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak flight] in
                guard let self, let flight, let index = self.waitingFlights.firstIndex(where: { $0 === flight }) else { return }
                self.waitingFlights.remove(at: index)
                flight.fadeAway()
            }
        } else if flies {
            waitingRecordings.append(rect)
        }
    }

    // MARK: - 截图飞到绳上（动画见 ClotheslineFlight）
    //
    // 顺序：截完 → 原位「咔嚓」一下被拎起来 → 写进「最近截图」、绳子放下来，新卡片从一开始就藏着 →
    // 卡片排好后沿弧线飞过去 → 落到那里，真卡片出现

    /// 已经咔嚓拎起来、等着飞的截图（按截的先后）
    private var waitingFlights: [ClotheslineFlight] = []
    /// 等着飞的录屏：录的那块区域（第一帧写好了才有图，到时从这里起飞）
    private var waitingRecordings: [CGRect] = []

    /// 新卡片已经在绳上（藏着）：飞过去，落下后真卡片出现
    /// - Parameter region: 录屏录的那块区域（截图用不上：截图的图在截的时候就已经在原位了）
    private func fly(_ flight: ClotheslineFlight?, recordedIn region: CGRect = .zero, to id: URL) {
        guard let item = model.items.first(where: { $0.id == id }), let target = photoFrame(of: item.entry) else {
            // 卡片没排出来（例如绳子已经收起）：原地淡掉
            flight?.fadeAway()
            if model.flyingID == id { model.flyingID = nil }
            return
        }
        let tilt = item.tilt
        if let flight { return launch(flight, to: target, tilt: tilt, id: id) }
        // 录屏：现在才有第一帧，在录的那块区域原位咔嚓一下再飞（不知道区域时从屏幕中间）
        guard let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let recording = ClotheslineFlight(image: image, from: region) else {
            if model.flyingID == id { model.flyingID = nil }
            return
        }
        recording.snap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.launch(recording, to: target, tilt: tilt, id: id) }
    }

    private func launch(_ flight: ClotheslineFlight, to target: CGRect, tilt: Double, id: URL) {
        flight.fly(to: target, cornerRadius: CardFrame.radius - CardFrame.inset, tilt: tilt) { [weak self] in
            guard let self else { return }
            // 先让真卡片出现，飞的那张下一帧再收掉
            // 真卡片在下面 0.16 秒淡入、飞的这张在上面淡出；落下的这张自己轻轻晃一下（见 PeggedView.land），「叮」一声
            if self.model.flyingID == id { self.model.flyingID = nil }
            SoundEffects.play(.hang)
        }
    }

    // MARK: - 风（和 Picline 一样：绳子放下来时，每隔 7～16 秒自己吹一阵，像一根真的绳子）

    /// 收起后这一轮的风就不再吹（每次放下来重新开始一轮）
    private var gustRound = 0

    private func scheduleGust() {
        gustRound += 1
        let round = gustRound
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self, self.gustRound == round, self.isRevealed else { return }
            if !self.model.items.isEmpty, self.model.draggingID == nil { self.model.breeze() }
            self.scheduleGust()
        }
    }

    private func peek(on screen: NSScreen?) {
        peekUntil = Date().addingTimeInterval(Self.peekDuration)
        if isRevealed {
            model.breeze()
        } else {
            reveal(on: screen, onPurpose: false)
        }
        peekTimer?.invalidate()
        let timer = Timer(timeInterval: Self.peekDuration, repeats: false) { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.peekFinished() }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekTimer = timer
    }

    private func peekFinished() {
        peekTimer = nil
        guard isRevealed, !pointerWasInside, !openedOnPurpose else { return }
        if isBusy { return }
        if !zone.contains(NSEvent.mouseLocation) { hide() }
    }

    /// 这些时候鼠标离开绳子也不收起：正在拖、菜单开着、按着照片、快速查看开着、
    /// 用 ⌘ / ⇧ 选中了几张（选好了要去别的窗口拖、要一起操作）。这时点绳子外面或按 ⌥F 收起
    private var isBusy: Bool {
        ClotheslineGrabView.isDragging || ClotheslineGrabView.isShowingMenu || model.pressedID != nil
            || ClotheslineQuickLook.shared.isOpen || !model.selectedIDs.isEmpty || carrying || model.catching
    }

    private var isPeeking: Bool { Date() < peekUntil && !pointerWasInside }

    // MARK: - 放下与收起

    /// 快捷键、菜单：放下或收起
    func toggle() {
        if isRevealed {
            hide()
        } else if isEnabled {
            reveal(on: Self.screenUnderPointer(), onPurpose: true)
        }
    }

    private func reveal(on screen: NSScreen?, onPurpose: Bool) {
        guard isEnabled, let screen else { return }
        releaseTask?.cancel()
        releaseTask = nil
        stopEdgeWatch()
        openedOnPurpose = onPurpose
        pointerWasInside = false
        updateCapacity(for: screen)
        model.reload()
        let panel = self.panel ?? makePanel()
        panel.place(on: screen)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        isRevealed = true
        // 下一轮再放下，SwiftUI 才有「从藏着的位置滑下来」的动画
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRevealed else { return }
            self.model.revealed = true
            self.model.breeze()
            self.scheduleGust()
        }
        installClickMonitors()
        updateMonitoring()
        Log.capture.notice("晾衣绳：放下来（\(onPurpose ? "快捷键或菜单" : "按住 ⌥ 移到最上面或拖图片过来", privacy: .public)），\(self.model.items.count) 张")
    }

    /// 在绳上做完一件事：先不收，等鼠标回到绳子上（再离开时照常收起）
    func holdUntilPointerReturnsToLine() {
        guard isRevealed else { return }
        holdUntilPointerReturns = true
        retractTimer?.invalidate()
        retractTimer = nil
    }

    func hide() {
        guard isRevealed else { return }
        isRevealed = false
        openedOnPurpose = false
        holdUntilPointerReturns = false
        retractTimer?.invalidate()
        retractTimer = nil
        peekTimer?.invalidate()
        peekTimer = nil
        peekUntil = .distantPast
        model.revealed = false
        gustRound += 1
        model.coachingText = nil
        model.clearSelection()
        panel?.ignoresMouseEvents = true
        ClotheslineQuickLook.shared.lineHidden()
        ClotheslineUndo.shared.pointerOnLine(false)
        hoveredID = nil
        updateDeleteKey(pointerOnLine: false)
        removeClickMonitors()
        updateMonitoring()
        // 收起的动画放完后：面板、缩略图全部释放（空闲时不留任何东西）
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !Task.isCancelled, !self.isRevealed else { return }
            self.panel?.orderOut(nil)
            self.panel?.contentView = nil
            self.panel = nil
            self.model.unload()
            self.releaseTask = nil
        }
        Log.capture.notice("晾衣绳：收起")
    }

    private func makePanel() -> ClotheslinePanel {
        let host = NSHostingView(rootView: ClotheslineView(model: model))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // 绳子下面垫一层能接收拖放的：拖着图片过来，松手就挂上
        let surface = ClotheslineDropSurface(frame: .zero)
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)
        surface.onDrop = { items in ClotheslineIntake.hang(items) }
        surface.onDragChange = { [weak self] inside in self?.model.catching = inside }
        let panel = ClotheslinePanel(content: surface)
        host.frame = surface.bounds
        // 双指左右滑、滚轮：保留数量多于放得下时往左看更早的
        panel.onScroll = { [weak self] event in
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.model.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        self.panel = panel
        return panel
    }

    // MARK: - 在访达里删了文件：绳子先下来，再当着你的面把那张拿掉

    /// 一直看着存好的截图、录屏所在的文件夹（绳子收着时也看）：系统有变化时来叫，平时不占资源
    private lazy var fileWatcher = FolderWatcher { ClotheslineController.shared.filesChanged() }
    private var removingDeleted = false

    /// 存好的文件在哪些文件夹：变了就换着看；关掉晾衣绳时不看
    /// - Parameter entries: 刚读好的「最近截图」（不传就现读一遍）
    func refreshFileWatch(entries: [ScreenshotHistory.Entry]? = nil) {
        guard isEnabled else { return fileWatcher.stop() }
        let files = ScreenshotHistory.shared.savedFiles(for: entries ?? ScreenshotHistory.entries())
        fileWatcher.watch(files.values.map { $0.deletingLastPathComponent().path })
    }

    /// 看着的文件夹有变化：有存好的文件被删了，就放下绳子，等它滑下来再把那几张拿掉（拿掉时有缩小淡出的动画）
    private func filesChanged() {
        guard isEnabled, !removingDeleted else { return }
        let gone = ScreenshotHistory.shared.deletedEntries()
        guard !gone.isEmpty else { return }
        removingDeleted = true
        let wasRevealed = isRevealed
        if wasRevealed {
            peekUntil = max(peekUntil, Date().addingTimeInterval(Self.peekDuration))
        } else {
            peek(on: Self.screenUnderPointer())
        }
        // 绳子滑下来、卡片都挂好（约 0.6 秒）后再拿掉，你能看清是哪一张走了
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasRevealed ? 0.1 : 0.7)) { [weak self] in
            self?.removingDeleted = false
            if ScreenshotHistory.shared.pruneDeletedFiles() > 0 { SoundEffects.play(.takeDown) }
        }
    }

    private func historyChanged() {
        let entries = ScreenshotHistory.entries()
        refreshFileWatch(entries: entries)   // 新存的文件可能在新的文件夹里
        historyCount = entries.count
        // 有一张要飞过来：先把它在绳上的卡片藏起来，再读一遍、放下绳子（这样它从头到尾都不会先露一下）
        // 先到先飞：截图按截的先后；没有在等的截图时才是录屏
        var flyingID: URL?
        var nextFlight: ClotheslineFlight?
        var recordingRegion = CGRect.zero
        var flies = false
        if pendingPeekScreen != nil {
            if !waitingFlights.isEmpty {
                nextFlight = waitingFlights.removeFirst()
                flies = true
            } else if !waitingRecordings.isEmpty {
                recordingRegion = waitingRecordings.removeFirst()
                flies = true
            }
        }
        if flies {
            flyingID = entries.first { !$0.pinned }?.url
            model.flyingID = flyingID
        }
        if isRevealed { model.reload() }
        updateMonitoring()
        if let screen = pendingPeekScreen {
            pendingPeekScreen = nil
            peek(on: screen)
            if let flyingID {
                // 等绳子滑下来、新卡片排好位置再飞
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.fly(nextFlight, recordedIn: recordingRegion, to: flyingID) }
            } else if let nextFlight {
                nextFlight.fadeAway()   // 没有新卡片可落（不该发生）：原地淡掉
            } else {
                SoundEffects.play(.hang)   // 不飞的（剪贴板、访达挂上来的）：挂上就「叮」一声
            }
        }
    }

    // MARK: - 鼠标（只靠系统通知，不轮询）

    /// 开着晾衣绳就听鼠标（移动、按下、拖动）：按住 ⌥ 移到顶部、拖着图片到顶部都要知道。关掉晾衣绳就整个撤掉
    private func updateMonitoring() {
        let wanted = isRevealed || isEnabled
        if wanted, eventTap == nil, moveMonitors.isEmpty {
            startListening()
        } else if !wanted {
            stopListening()
        }
    }

    private func startListening() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        // 只听（listenOnly）：不修改、不拦截任何事件。只听鼠标不听键盘，不需要「输入监控」权限
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { ClotheslineController.shared.reenableTap() }
            } else {
                let flags = event.flags
                MainActor.assumeIsolated {
                    ClotheslineController.shared.mouseEvent(type, option: ClotheslineModifier.current.isHeld(in: flags))
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                       eventsOfInterest: mask, callback: callback, userInfo: nil),
           let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            eventTap = tap
            eventTapSource = source
            Log.capture.notice("晾衣绳：开始听鼠标（事件分接）")
            return
        }
        // 拿不到事件分接（极少见）：退回 NSEvent 全局监听（鼠标在有些地方时收不到）
        Log.capture.error("晾衣绳：事件分接不可用，改用 NSEvent 监听")
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        let handler: (NSEvent) -> Void = { event in
            let type: CGEventType = switch event.type {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .leftMouseDragged: .leftMouseDragged
            default: .mouseMoved
            }
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                ClotheslineController.shared.mouseEvent(type, option: flags.contains(ClotheslineModifier.current.flag))
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) { moveMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { handler($0); return $0 }) {
            moveMonitors.append(local)
        }
    }

    private func stopListening() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        eventTapSource = nil
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
        stopEdgeWatch()
    }

    /// 系统嫌处理太慢（或用户输入）时会暂停事件分接：再打开
    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    private func mouseEvent(_ type: CGEventType, option: Bool) {
        let point = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            pressStarted()
        case .leftMouseUp:
            if pressSince != nil { pressEnded() }
        case .leftMouseDragged:
            if pressSince != nil { carryTick() }
            pointerMoved(to: point, option: option)
        default:
            pointerMoved(to: point, option: option)
        }
    }

    // MARK: - 拖着图片到屏幕顶部（移植自 Picline 的 carrying）

    /// 按下鼠标键的时刻、之后移动了多远、拖放剪贴板当时的计数（变了才说明开始拖东西了）
    private var pressSince: Date?
    private var pressTravel: CGFloat = 0
    private var lastPointer: CGPoint?
    private var dragCountAtPress = 0
    private var carryTimer: Timer?
    /// 正拖着图片（按住超过 0.25 秒、移动超过 5 点、拖的是图片或文件）
    private(set) var carrying = false

    /// 按下 0.25 秒以上、移动 5 点以上才算在拖：单击菜单栏、手指停在顶上不动都不算
    nonisolated static let pressHold: TimeInterval = 0.25
    nonisolated static let pressTravelNeeded: CGFloat = 5

    /// 屏幕最上面两个菜单栏那么高的一条（整个宽度）：拖着图片进到这里，绳子就下来接
    static func catchBand(of screen: NSScreen) -> CGRect {
        let height = menuBarBand(of: screen).height * 2
        // 多算 1 点，最上沿那一行（y 正好等于 maxY）也在里面
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height + 1)
    }

    private func pressStarted() {
        guard isEnabled else { return }
        pressSince = Date()
        pressTravel = 0
        lastPointer = NSEvent.mouseLocation
        dragCountAtPress = NSPasteboard(name: .drag).changeCount
        carryTimer?.invalidate()
        carryTimer = nil
        // 有事件分接时，拖动的每一步都会抄送过来，不用计时；
        // 退回 NSEvent 监听时拖放过程中收不到移动事件：按着键期间每秒看 20 次，松开就停
        guard eventTap == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.carryTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        carryTimer = timer
    }

    private func carryTick() {
        let point = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 != 0, let since = pressSince else { return pressEnded() }
        if let last = lastPointer { pressTravel += hypot(point.x - last.x, point.y - last.y) }
        lastPointer = point
        let dragging = NSPasteboard(name: .drag)
        let carriesPicture = dragging.changeCount != dragCountAtPress
            && (dragging.types ?? []).contains { [.fileURL, .png, .tiff].contains($0) }
        carrying = carriesPicture && Date().timeIntervalSince(since) >= Self.pressHold && pressTravel >= Self.pressTravelNeeded
        guard carrying, let screen = NSScreen.screen(containing: point) else { return }
        if !isRevealed, Self.catchBand(of: screen).contains(point), !ClotheslineOverview.isUp() {
            reveal(on: screen, onPurpose: false)
        }
        // 绳子在接：整个面板都接收拖放（平时只有卡片上接收鼠标）
        if isRevealed, let panel, panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
    }

    private func pressEnded() {
        carryTimer?.invalidate()
        carryTimer = nil
        pressSince = nil
        let wasCarrying = carrying
        carrying = false
        model.catching = false
        if wasCarrying, isRevealed { pointerMoved(to: NSEvent.mouseLocation) }
    }

    /// 鼠标动了（系统抄送过来的）
    /// - Parameter option: 按着设置里选的那个键（默认 ⌥）
    func pointerMoved(to point: CGPoint, option: Bool? = nil) {
        let held = option ?? NSEvent.modifierFlags.contains(ClotheslineModifier.current.flag)
        if isRevealed {
            updateWhileRevealed(point)
        } else {
            checkTopEdge(point, option: held)
        }
    }

    /// 屏幕最上面那一条（2 点高）：按住 ⌥ 把鼠标移到这里，绳子就下来
    static func topEdge(of screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX, y: screen.frame.maxY - 3, width: screen.frame.width, height: 3)
    }

    /// 鼠标是不是碰到了这块屏幕的最上沿。注意：鼠标在最上面一行时，坐标的 y 正好等于屏幕的 maxY，
    /// 而 CGRect.contains 不算上边线，所以这里两头都算进去（以前漏了这一点，碰到最上沿反而不算）
    static func isAtTopEdge(_ point: CGPoint, of screen: NSScreen) -> Bool {
        let frame = screen.frame
        return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.maxY - 3 && point.y <= frame.maxY + 1
    }

    /// 鼠标碰到哪块屏幕的最上沿（多块屏幕时按 x 找，上沿那一行可能不被 frame.contains 算进去）
    static func screenAtTopEdge(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { isAtTopEdge(point, of: $0) }
    }

    /// 绳子收着：鼠标到了屏幕最上面、按着 ⌥（没按着鼠标键）就放下来。全屏 App 里也一样
    private func checkTopEdge(_ point: CGPoint, option: Bool) {
        guard isEnabled, Preferences.shared.clotheslineHover, NSEvent.pressedMouseButtons == 0,
              let screen = Self.screenAtTopEdge(point), !ClotheslineOverview.isUp() else {
            return stopEdgeWatch()
        }
        if option {
            stopEdgeWatch()
            reveal(on: screen, onPurpose: false)
        } else {
            // 鼠标先到了顶上、还没按 ⌥：停着不动就没有事件了，接下来 3 秒里每秒看 10 次 ⌥
            startEdgeWatch()
        }
    }

    private func startEdgeWatch() {
        edgeWatchUntil = Date().addingTimeInterval(3)
        guard edgeWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.edgeWatchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeWatch = timer
    }

    private func edgeWatchTick() {
        let point = NSEvent.mouseLocation
        guard !isRevealed, Date() < edgeWatchUntil, let screen = Self.screenAtTopEdge(point) else { return stopEdgeWatch() }
        if NSEvent.modifierFlags.contains(ClotheslineModifier.current.flag), NSEvent.pressedMouseButtons == 0 {
            stopEdgeWatch()
            reveal(on: screen, onPurpose: false)
        }
    }

    private func stopEdgeWatch() {
        edgeWatch?.invalidate()
        edgeWatch = nil
    }

    // MARK: - Delete 取下（鼠标在绳子上、有选中的或指着一张时才借用 Delete 键，离开就还回去）

    /// 鼠标正指着的那张
    private var hoveredID: URL?
    private var deleteKey: UInt32?

    private func updateDeleteKey(pointerOnLine: Bool) {
        let wanted = pointerOnLine && (!model.selectedIDs.isEmpty || hoveredID != nil)
        if wanted, deleteKey == nil {
            deleteKey = HotkeyManager.shared.addTemporary(keyCode: kVK_Delete, modifiers: 0) { [weak self] in
                self?.deletePressed()
            }
        } else if !wanted, let key = deleteKey {
            HotkeyManager.shared.removeTemporary(key)
            deleteKey = nil
        }
    }

    /// 按 Delete：有选中的就取下选中的全部，否则取下鼠标指着的那张（和右键「取下」一样，⌘Z 能放回来）
    private func deletePressed() {
        guard let id = model.selectedIDs.first(where: { id in model.items.contains { $0.id == id } }) ?? hoveredID else { return }
        model.remove(id)   // 选中了几张时，remove 会取下选中的全部
        hoveredID = nil
        updateDeleteKey(pointerOnLine: false)
        holdUntilPointerReturnsToLine()
    }

    /// 绳子放下来：鼠标在卡片上时面板接收点击，其他地方点击穿透；离开绳子 0.5 秒收起
    private func updateWhileRevealed(_ point: CGPoint) {
        guard let panel else { return }
        // 调度中心开了：立刻让开（不然会接走本来要拖到另一个桌面的窗口）
        if ClotheslineOverview.isUp() { return hide() }
        if !ClotheslineGrabView.isDragging, !carrying {
            let local = panel.convertPoint(fromScreen: point)
            let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
            let hit = model.hitRects.first { $0.value.insetBy(dx: -4, dy: -4).contains(flipped) }?.key
            var overCard = hit != nil
            // 能滚动的绳子：照片挂着的那一横条（包括空隙）也接收鼠标，在上面滑动就能滚
            if !overCard, ClotheslineLayout.keep > 0, model.items.count > model.visibleCount {
                let band = model.hitRects.values.reduce(CGRect.null) { $0.union($1) }
                overCard = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
            }
            if panel.ignoresMouseEvents == overCard { panel.ignoresMouseEvents = !overCard }
            // 鼠标停在卡片上时借用空格键（快速查看），离开就还回去
            ClotheslineQuickLook.shared.pointerOver(model.items.map(\.entry), index: hit.flatMap { id in model.items.firstIndex { $0.id == id } })
            hoveredID = hit
        }
        ClotheslineUndo.shared.pointerOnLine(zone.contains(point))
        updateDeleteKey(pointerOnLine: zone.contains(point))
        if zone.contains(point) {
            pointerWasInside = true
            holdUntilPointerReturns = false
            retractTimer?.invalidate()
            retractTimer = nil
        } else if retractTimer == nil, !(openedOnPurpose && !pointerWasInside), !isPeeking, model.selectedIDs.isEmpty,
                  !holdUntilPointerReturns {
            // 刚截完图挂上来的那 2.5 秒里鼠标在别处是正常的，不因此收起（到点由 peekFinished 收）
            scheduleRetract()
        }
    }

    /// 绳子占的范围：从最低处到屏幕顶（包括菜单栏），往上移不会收起
    private var zone: CGRect {
        guard let panel else { return .null }
        var zone = panel.frame
        // 一直到屏幕最上沿再多一点（鼠标顶在最上面时 y 等于屏幕的 maxY，contains 不算上边线）
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY + 2 }
        return zone
    }

    private func scheduleRetract() {
        let timer = Timer(timeInterval: Self.retractDelay, repeats: false) { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.retractFinished() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retractTimer = timer
    }

    private func retractFinished() {
        retractTimer = nil
        guard isRevealed else { return }
        // 正在拖、菜单开着、按着照片、选中了几张：等一会儿再看；刚做完一件事：等鼠标回来
        if isBusy { return scheduleRetract() }
        if holdUntilPointerReturns { return }
        if !zone.contains(NSEvent.mouseLocation) { hide() }
    }

    /// 绳子放下来期间：点绳子外面任何地方（包括菜单栏）就收起
    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { ClotheslineController.shared.clickedElsewhere(at: NSEvent.mouseLocation) }
        }) { clickMonitors.append(global) }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    /// 点在别的 App 上（Velos 自己的窗口收到的点击不经过全局监听）
    private func clickedElsewhere(at point: CGPoint) {
        // 快速查看开着时点别处只是关预览，绳子留着
        guard isRevealed, !ClotheslineGrabView.isShowingMenu, !ClotheslineQuickLook.shared.isOpen else { return }
        hide()
    }

    // MARK: - 屏幕区域

    static func screenUnderPointer() -> NSScreen? {
        NSScreen.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 屏幕顶上的菜单栏那一条
    static func menuBarBand(of screen: NSScreen) -> CGRect {
        var height = screen.frame.maxY - screen.visibleFrame.maxY
        if height < 1 { height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    #if DEBUG
    var debugModel: ClotheslineModel { model }
    var debugPanel: NSPanel? { panel }
    var debugIsListening: Bool { eventTap != nil || !moveMonitors.isEmpty }
    var debugUsesEventTap: Bool { eventTap != nil }
    /// 自测：假装鼠标移到了这里（不动用户的鼠标），option 表示按着 ⌥
    func debugPointer(at point: CGPoint, option: Bool = false) { pointerMoved(to: point, option: option) }
    func debugFinishRetract(pointer: CGPoint) {
        retractTimer?.invalidate()
        retractTimer = nil
        if isRevealed, !zone.contains(pointer) { hide() }
    }
    var debugIsWaitingToRetract: Bool { retractTimer != nil }
    #endif
}

/// 屏幕顶上一条透明的面板：浮在所有 App、所有桌面上，从不抢焦点，只有卡片上能点，其他地方点击穿透
final class ClotheslinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 双指滑动、滚轮：绳子长的时候左右滚
    var onScroll: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    /// 挂在菜单栏下面，和屏幕一样宽
    func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        // 往下多留一点：拖着图片过来时虚线框挂得下
        let height = ClotheslineLayout.panelHeight + 44   // 往下多留一点：虚线框、第一次使用的两行提示放得下
        let target = CGRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
        if frame != target { setFrame(target, display: true) }
    }
}

/// 按住哪个键把鼠标移到最上面时放下晾衣绳（设置里选，默认 ⌥）
enum ClotheslineModifier: String, CaseIterable, Identifiable {
    case command, option, control, shift
    var id: Self { self }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }

    func isHeld(in flags: CGEventFlags) -> Bool {
        switch self {
        case .command: flags.contains(.maskCommand)
        case .option: flags.contains(.maskAlternate)
        case .control: flags.contains(.maskControl)
        case .shift: flags.contains(.maskShift)
        }
    }

    @MainActor static var current: ClotheslineModifier {
        ClotheslineModifier(rawValue: Preferences.shared.clotheslineModifier) ?? .option
    }
}
