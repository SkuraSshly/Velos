import AppKit
import SwiftUI

/// 设置窗口左侧的栏目
enum SettingsTab: String, CaseIterable {
    case general, screenshot, recording, translate, clothesline, hotkeys

    var title: String {
        switch self {
        case .general: "通用"
        case .screenshot: "截图"
        case .clothesline: "晾衣绳"
        case .recording: "录屏"
        case .translate: "截屏翻译"
        case .hotkeys: "快捷键"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screenshot: "camera.viewfinder"
        case .clothesline: Glyph.clothesline
        case .recording: "record.circle"
        case .translate: "character.bubble"
        case .hotkeys: "command"
        }
    }

    /// 图标小方块的暖色（和 2.7 一样）
    var tint: Color {
        switch self {
        case .general: .chipCocoa
        case .screenshot: .chipSky
        case .clothesline: .accent
        case .recording: .hot
        case .translate: .chipSage
        case .hotkeys: .chipLavender
        }
    }
}

/// 当前选中的栏目、鼠标悬停的栏目（侧栏和内容共享）
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var hovered: SettingsTab?
}

/// 设置窗口：温暖的奶油色磨砂（和图标、截图工具栏一套颜色）。左侧是栏目，选中块是杏色的液态玻璃、换栏目时流过去；右侧是对应的设置。
/// 窗口大小固定，切换栏目时窗口不变（内容多的页面在右侧滚动），不会跳动。
/// 窗口按需创建，关闭后整个控制器释放，不常驻内存。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var current: SettingsWindowController?
    /// 默认大小，也是最小大小（可以拖边缘调大、用绿色按钮缩放）
    static let size = CGSize(width: 640, height: 460)

    private let window: NSWindow
    private let selection = SettingsSelection()

    static func show(_ tab: SettingsTab? = nil) {
        if let controller = current {
            if let tab { controller.select(tab) }
            controller.present()
            return
        }
        let controller = SettingsWindowController(tab: tab ?? .general)
        current = controller
        controller.present()
    }

    private init(tab: SettingsTab) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()

        // 标题栏透明、不显示标题（窗口标题仍按栏目设置，供辅助功能和「窗口」菜单使用）
        window.identifier = .velosCapturable   // 设置窗口和其他窗口一样能被截图
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.allowFullScreen()
        window.backgroundColor = .clear
        window.isOpaque = false
        // 设置窗口固定用浅色的奶油底（不跟随系统），其他窗口照常跟随系统
        window.appearance = NSAppearance(named: .aqua)

        selection.tab = tab
        let root = SettingsRootView(selection: selection) { [weak self] tab in self?.select(tab) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []   // 窗口大小由用户决定，不随内容变化（最小尺寸见 windowWillResize）
        window.contentViewController = host
        window.setContentSize(Self.size)
        applyMinimumSize()

        window.isReleasedWhenClosed = false
        window.delegate = self
        // 第一次显示不要动画：否则窗口的第一次布局落在动画里，左上角的「Velos 设置」等会从角落飞进来
        window.title = tab.title
        window.centerOnScreen()
    }

    /// 最小就是默认大小。SwiftUI 的承载控制器会把窗口的最小尺寸清零，所以每次显示前再设一次，
    /// 拖边缘时再由 windowWillResize 兜底
    private func applyMinimumSize() {
        window.minSize = Self.minimumFrameSize
    }

    /// 窗口外框的最小尺寸（全尺寸内容视图：外框就是内容区域）
    static let minimumFrameSize = size

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minimumFrameSize.width), height: max(frameSize.height, Self.minimumFrameSize.height))
    }

    private func present() {
        applyMinimumSize()
        window.bringToFront()
    }

    private func select(_ tab: SettingsTab) {
        guard tab != selection.tab else { return }
        selection.tab = tab
        window.title = tab.title
    }

    func windowWillClose(_ notification: Notification) {
        // 二级窗口（选文件夹等）跟着一起关
        window.childWindows?.forEach { $0.close() }
        Self.current = nil
    }

    /// 打开着的设置窗口（二级界面以表单形式挂在它上面）
    static var currentWindow: NSWindow? { current?.window }

    #if DEBUG
    var debugWindow: NSWindow { window }
    static var debugCurrent: SettingsWindowController? { current }
    #endif
}

/// 左侧栏目 + 右侧设置：整扇窗是一块磨砂，左边栏目、右边一组组半透明卡片
private struct SettingsRootView: View {
    @ObservedObject var selection: SettingsSelection
    let onSelect: (SettingsTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection, onSelect: onSelect)
                .frame(width: 180)
            Rectangle().fill(Color.hairline).frame(width: 0.5)
            ScrollView {
                page
                    .padding(.top, 26)   // 让出透明标题栏
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .id(selection.tab)   // 换栏目时从顶部开始
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsWindowController.size.width, maxWidth: .infinity,
               minHeight: SettingsWindowController.size.height, maxHeight: .infinity)
        .fontDesign(.rounded)
        .tint(.accent)
        .background(WarmWindowBackground())
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch selection.tab {
        case .general: GeneralSettingsView()
        case .screenshot: ScreenshotSettingsView()
        case .clothesline: ClotheslineSettingsView()
        case .recording: RecordingSettingsView()
        case .translate: TranslateSettingsView()
        case .hotkeys: HotkeySettingsView()
        }
    }
}

/// 左侧栏目：暖色图标小方块 + 名称；选中的是一块杏色的液态玻璃，换栏目时像液体一样流过去（和标注工具栏一样）
private struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsSelection
    let onSelect: (SettingsTab) -> Void

    private let rowHeight: CGFloat = 36
    private let tabs = SettingsTab.allCases
    /// 侧栏左右留的空
    private let inset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 让出左上角的红绿灯
            Spacer().frame(height: 46)
            // 字标：图标配色的渐变字 + 扫描线 + 光点
            VelosWordmark(fontSize: 28)
                .padding(.leading, inset + 10)
                .padding(.bottom, 12)

            let index = CGFloat(tabs.firstIndex(of: selection.tab) ?? 0)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    LiquidSelection(rect: CGRect(x: 0, y: index * rowHeight + 2, width: proxy.size.width, height: rowHeight - 4),
                                    cornerRadius: 10)
                    VStack(spacing: 0) {
                        ForEach(tabs, id: \.self) { tab in
                            row(tab)
                        }
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(tabs.count))
            .padding(.horizontal, inset)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.settingsCard.opacity(0.45))
    }

    private func row(_ tab: SettingsTab) -> some View {
        let selected = tab == selection.tab
        return HStack(spacing: 10) {
            IconChip(symbol: tab.symbol, tint: selected ? Color.white.opacity(0.25) : tab.tint, side: 24)
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(selected ? Color.white : Color.ink)
                .animation(.easeOut(duration: 0.15), value: selected)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.glassTrack)
                .padding(.vertical, 2)
                .opacity(!selected && selection.hovered == tab ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { selection.hovered = tab } else if selection.hovered == tab { selection.hovered = nil }
        }
        .onTapGesture { onSelect(tab) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
