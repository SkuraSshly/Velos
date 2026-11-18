import AppKit
import Combine

/// 菜单栏图标与菜单。
/// 图标可以在设置里隐藏：隐藏时直接移除 NSStatusItem，而不是只把它设为不可见。
/// 录制中图标变成红点 + 计时，暂停时变成杏色暂停图标（图标被隐藏时不显示，录制控制交给浮动控制条）。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var observers: Set<AnyCancellable> = []
    /// 录制计时，只在录制期间运行（空闲时没有任何定时器）
    private var recordingTimer: Timer?

    #if DEBUG
    nonisolated(unsafe) static weak var debugCurrent: StatusBarController?
    var debugHasStatusItem: Bool { statusItem != nil }
    var debugMenuTitles: [String] { rebuildMenu(); return menu.items.map(\.title) }
    #endif

    override init() {
        super.init()
        #if DEBUG
        Self.debugCurrent = self
        #endif
        menu.delegate = self
        menu.autoenablesItems = false

        // 订阅「显示菜单栏图标」设置；订阅时会立即收到当前值，从而完成首次创建
        Preferences.shared.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in self?.setIconVisible(visible) }
            .store(in: &observers)
        RecordingManager.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.recordingStateChanged(state) }
            .store(in: &observers)
    }

    private func setIconVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // 不设悬停提示：菜单栏图标的提示框在绳子从顶部放下来、菜单打开时容易收不到「鼠标离开」，
            // 一个「Velos」小标签就会一直停在屏幕上。名字给读屏用
            item.button?.setAccessibilityLabel("Velos")
            item.menu = menu
            statusItem = item
            updateIcon()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - 录制状态

    private func recordingStateChanged(_ state: RecordingManager.State) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if state == .recording || state == .paused {
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateIcon() }
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let item = statusItem, let button = item.button else { return }
        let manager = RecordingManager.shared
        if manager.isRecording {
            // 红色圆点（暂停时是杏色暂停图标）+ 已录制时长（不含暂停）
            item.length = NSStatusItem.variableLength
            let paused = manager.isPaused
            let config = NSImage.SymbolConfiguration(paletteColors: [paused ? WarmPalette.apricot : OverlayAccent.recording])
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                   accessibilityDescription: paused ? "录制已暂停" : "正在录制")?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + DurationFormat.clock(manager.elapsed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
            button.setAccessibilityLabel((paused ? "录制已暂停" : "正在录制") + " · \(CaptureCoordinator.shared.recordingHotkey.displayString) 停止")
        } else {
            item.length = NSStatusItem.squareLength
            button.image = VelosMark.menuBar   // 自己画的花体 V（模板图：自动适配浅色 / 深色菜单栏）
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel("Velos")
        }
    }

    // MARK: - 菜单

    /// 每次打开菜单前重建，确保权限状态等信息是最新的（菜单不打开时不做任何事，空闲 CPU 为 0）
    func menuNeedsUpdate(_ menu: NSMenu) {
        PermissionManager.shared.refresh()
        rebuildMenu()
    }

    /// 菜单开着时，全局快捷键会被系统压着、等菜单关了才送到（按 ⌥A 没反应，关菜单时才开始截图）。
    /// 所以菜单开着时先把全局快捷键让出来：按键直接交给菜单，菜单项上标着同样的快捷键，按 ⌥A 就是点「截图」，菜单随即关上
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        HotkeyManager.shared.pauseAll()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        HotkeyManager.shared.resumeAll()
    }

    /// 程序坞图标的右键菜单：和菜单栏菜单一样的内容（不带快捷键提示；「退出」由系统自己加在程序坞菜单里）
    func makeDockMenu() -> NSMenu {
        PermissionManager.shared.refresh()
        let dockMenu = NSMenu()
        dockMenu.autoenablesItems = false
        build(into: dockMenu, forDock: true)
        return dockMenu
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        build(into: menu, forDock: false)
    }

    private func build(into menu: NSMenu, forDock: Bool) {
        @discardableResult
        func addItem(_ title: String, action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: forDock ? "" : key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
            return item
        }

        if !PermissionManager.shared.screenRecordingGranted {
            let warning = addItem("授予屏幕录制权限…", action: #selector(showPermissions))
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }

        // 菜单里的快捷键只做显示，真正的全局快捷键由 HotkeyManager 注册
        let recordingState = RecordingManager.shared.state

        // 菜单尽量简单：四个功能 + 设置 + 退出。录制中「录屏」变成「停止录制」（暂停在录制控制条上）
        func addAction(_ title: String, _ action: HotkeyManager.Action, _ selector: Selector) -> NSMenuItem {
            let key = CaptureCoordinator.shared.hotkey(for: action)
            return addItem(title, action: selector, key: key.menuKeyEquivalent, modifiers: key.cocoaModifiers)
        }
        _ = addAction("截图", .screenshot, #selector(takeScreenshot))
        if recordingState == .recording || recordingState == .paused {
            _ = addAction("停止录制", .recording, #selector(stopRecording))
        } else {
            let record = addAction("录屏", .recording, #selector(startRecording))
            record.isEnabled = recordingState == .idle
        }
        _ = addAction("截屏翻译", .translate, #selector(startTranslate))
        if Preferences.shared.clotheslineEnabled {
            _ = addAction("晾衣绳", .clothesline, #selector(toggleClothesline))
        }

        menu.addItem(.separator())
        // 有快捷键被别的程序占用：只出一行，点了去快捷键设置看是哪个
        if !HotkeyManager.shared.failedActions.isEmpty {
            let warning = addItem("有快捷键被其他程序占用…", action: #selector(openHotkeySettings))
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        addItem("设置…", action: #selector(openSettings), key: ",")
        guard !forDock else { return }
        let quit = addItem("退出 Velos", action: #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
    }

    @objc private func openHotkeySettings() {
        SettingsLauncher.open(.hotkeys)
    }

    @objc private func takeScreenshot() {
        // 等菜单淡出后再冻屏，避免把菜单截进去
        CaptureCoordinator.shared.beginScreenshot(delay: .milliseconds(250))
    }

    @objc private func startRecording() {
        CaptureCoordinator.shared.beginRecording(delay: .milliseconds(150))
    }

    @objc private func startTranslate() {
        // 等菜单淡出后再冻屏
        CaptureCoordinator.shared.beginScreenshot(delay: .milliseconds(250), purpose: .translate)
    }

    @objc private func toggleClothesline() {
        // 等菜单收起后再放下来（菜单开着时点菜单栏会把绳子收回去）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClotheslineController.shared.toggle() }
    }

    @objc private func stopRecording() {
        Task { await RecordingManager.shared.stop() }
    }

    @objc private func showPermissions() {
        SettingsLauncher.openOnboarding()
    }

    @objc private func openSettings() {
        SettingsLauncher.open()
    }
}
