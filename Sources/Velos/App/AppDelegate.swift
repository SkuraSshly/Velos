import AppKit
import Combine
import Quartz

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var dockIconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        // 设置进程（见 SettingsProcess）：只显示设置窗口，不注册快捷键、不显示菜单栏图标，什么别的都不做
        if SettingsProcess.isSettingsProcess {
            PermissionManager.shared.refresh()
            SettingsProcessController.shared.start()
            return
        }
        statusBar = StatusBarController()
        // 程序坞图标（设置里可以打开）：显示时是普通 App，不显示时是只在菜单栏的工具
        dockIconObserver = Preferences.shared.$showDockIcon.removeDuplicates().sink { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
        PermissionManager.shared.refresh()
        CaptureCoordinator.shared.start()
        ScreenshotHistory.shared.start()
        ClotheslineUndo.shared.finalizeAll()   // 上次退出时没处理完的取下（异常退出才会有）
        ClotheslineController.shared.start()
        UpdateChecker.shared.start()   // 默认不自动检查：设置里打开了才定时去问
        LaunchAtLogin.shared.reregisterIfEnabled()   // 登录项指向正在运行的这一份 App
        ScreenTranslateController.shared.warmUpAllIfNeeded()   // 一次性：让系统预先编译文字识别模型
        DispatchQueue.global(qos: .utility).async { CapturedImage.removeStaleSharingFiles() }
        Log.capture.notice("Velos 已启动，屏幕录制权限：\(PermissionManager.shared.screenRecordingGranted ? "已授权" : "未授权", privacy: .public)")

        // 只有第一次运行、还没有屏幕录制权限时打开设置 › 通用（授权按钮在那里）；之后的每次启动（包括开机自启）都不弹出任何窗口
        if !Preferences.shared.hasCompletedOnboarding {
            Preferences.shared.hasCompletedOnboarding = true
            if !PermissionManager.shared.screenRecordingGranted { SettingsLauncher.openPermissions() }
        }

        #if DEBUG
        DebugSnapshots.runIfRequested()
        DebugMemoryProbe.runIfRequested()
        DebugMemoryShot.runIfRequested()
        DebugSnapshots.runSelfTestIfRequested()
        DebugUITest.runIfRequested()
        DebugPermissionRequest.runIfRequested()
        DebugRecordingTest.runIfRequested()
        DebugFeatureTest.runIfRequested()
        DebugSplitTest.runIfRequested()
        DebugSoundTest.runIfRequested()
        DebugShowcase.runIfRequested()
        DebugShowcase.runSettingsShotsIfRequested()
        #endif
    }

    /// Velos 已在运行时再次打开它（访达双击、启动台、Spotlight、`open` 命令）会走到这里。
    /// 菜单栏图标被隐藏后，这是除快捷键之外找回设置的唯一入口，所以直接打开设置窗口。
    /// 程序坞图标的右键菜单（显示程序坞图标时）
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusBar?.makeDockMenu()
    }

    // MARK: 快速查看（晾衣绳上按空格）

    /// 系统的快速查看窗口按响应链找谁提供内容：Velos 没有焦点窗口时问到这里，转给晾衣绳
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { ClotheslineQuickLook.shared.take(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { ClotheslineQuickLook.shared.release(panel) }


    /// 访达里「打开方式 → Velos」、把图片拖到程序坞里的 Velos 图标上：挂到晾衣绳上
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !SettingsProcess.isSettingsProcess else { return }
        guard ClotheslineController.shared.isEnabled else {
            let alert = NSAlert()
            alert.messageText = "晾衣绳没有打开"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "好")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { SettingsLauncher.open(.clothesline) }
            return
        }
        ClotheslineIntake.hang(files: urls)
    }

    /// 退出前：晾衣绳上暂存着等撤销的，按原来的意思处理掉（取下的进废纸篓）
    func applicationWillTerminate(_ notification: Notification) {
        guard !SettingsProcess.isSettingsProcess else { return }
        ClotheslineUndo.shared.finalizeAll()
    }

    /// Velos 已在运行时再次打开它，或者点了程序坞里的图标：打开设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsLauncher.open()
        return false
    }
}

extension AppDelegate {
    /// 隐藏的主菜单：菜单栏应用不显示菜单栏，但 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 这些快捷键要靠「编辑」菜单分发给输入框，
    /// 没有它时设置、翻译结果等窗口里的输入框按快捷键没反应。截图界面、编辑窗口、翻译窗口自己的快捷键会先被它们拦下，不受影响。
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        appMenu.addItem(withTitle: "退出 Velos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
