import AppKit

// 截图工具栏、录制选项条、下拉菜单、缩略图共用的「温暖、圆润、半透明磨砂」风格（和 2.7 一样，和橙色图标一致）：
// - 底座是系统的毛玻璃，上面叠一层奶油色（深色模式下是可可色）的半透明暖色；胶囊形外形、柔和的投影
// - 选中、「完成」用杏色，「开始录制」用珊瑚红，图标和文字是暖棕色
// - 一组按钮里的选中块（标注工具、帧率、录屏的声音 / 麦克风 / 指针）是染成杏色的液态玻璃，换选中项时像液体一样流过去（见 NativeGlassLens）

// MARK: - 配色

/// AppKit 界面（截图工具栏、控制条、缩略图等浮在屏幕上的磨砂面板）的配色。
/// 主色 accent（杏色）、hot（珊瑚红）也是设置窗口（SwiftUI，见 SettingsPane.swift 的 Color 扩展）的来源；
/// 文字、细线这几种两边分别按各自的底色调过、数值略有不同，改动时两边一起看
struct WarmPalette {
    let isDark: Bool

    init(for view: NSView) {
        isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 杏色：选中的工具、「完成」按钮、选区
    static let accent = NSColor(srgbRed: 0.96, green: 0.58, blue: 0.36, alpha: 1)
    /// 深一点的杏色：自绘光标的细边，浅色背景上也有清楚的轮廓
    static let accentEdge = NSColor(srgbRed: 0.80, green: 0.42, blue: 0.22, alpha: 1)
    /// 浅杏色和它的细边：调整大小光标里朝里的那个小三角
    static let accentPale = NSColor(srgbRed: 0.99, green: 0.84, blue: 0.73, alpha: 1)
    static let accentPaleEdge = NSColor(srgbRed: 0.90, green: 0.66, blue: 0.52, alpha: 1)
    /// 可可色：浅色模式的正文、移动光标的圆心
    static let deepInk = NSColor(srgbRed: 0.33, green: 0.24, blue: 0.18, alpha: 1)
    /// 珊瑚红：「开始录制」、录屏的选区
    static let hot = NSColor(srgbRed: 0.93, green: 0.37, blue: 0.30, alpha: 1)
    /// 投影：暖棕色
    static let shadow = NSColor(srgbRed: 0.25, green: 0.15, blue: 0.08, alpha: 1)

    /// 叠在毛玻璃上的暖色
    var tint: NSColor {
        isDark ? NSColor(srgbRed: 0.24, green: 0.19, blue: 0.16, alpha: 0.5)
               : NSColor(srgbRed: 1.00, green: 0.965, blue: 0.925, alpha: 0.5)
    }
    /// 外轮廓细线
    var hairline: NSColor {
        isDark ? NSColor(srgbRed: 1, green: 0.9, blue: 0.8, alpha: 0.16)
               : NSColor(srgbRed: 0.45, green: 0.33, blue: 0.22, alpha: 0.16)
    }
    /// 图标和文字
    var ink: NSColor {
        isDark ? NSColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 1)
               : NSColor(srgbRed: 0.36, green: 0.27, blue: 0.20, alpha: 1)
    }
    var secondaryInk: NSColor { ink.withAlphaComponent(0.55) }
    /// 鼠标悬停的底色
    var hover: NSColor {
        isDark ? NSColor(srgbRed: 1, green: 0.86, blue: 0.74, alpha: 0.13)
               : NSColor(srgbRed: 0.62, green: 0.42, blue: 0.26, alpha: 0.11)
    }
    var pressed: NSColor { hover.withAlphaComponent(hover.alphaComponent * 1.9) }
    var separator: NSColor { ink.withAlphaComponent(0.14) }
}

/// 圆润的字体（数字、字母用 SF Rounded；中文自动回落到苹方）
/// - Parameter monospacedDigits: 数字等宽（坐标、尺寸这类不断变化的数字不会左右跳动）
func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSFont {
    let base = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                : NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

// MARK: - 磨砂面板

/// 半透明磨砂的圆角面板：毛玻璃 + 暖色 + 细边 + 柔和投影。控件直接加为它的子视图。
final class FrostedPanel: NSView {
    private let effect = NSVisualEffectView()
    private let tintView = NSView()
    /// nil 表示胶囊形（圆角 = 高度的一半）
    var cornerRadius: CGFloat? { didSet { needsLayout = true } }

    /// - Parameters:
    ///   - blending: 截图界面用 .withinWindow（虚化下面冻结的画面），录屏界面用 .behindWindow（虚化后面实时的屏幕）
    ///   - shadowRadius: 投影大小；小标签用小一点的投影
    init(cornerRadius: CGFloat? = nil, blending: NSVisualEffectView.BlendingMode, shadowRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = WarmPalette.shadow.cgColor
        layer?.shadowOpacity = shadowRadius < 10 ? 0.18 : 0.22
        layer?.shadowRadius = shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: shadowRadius < 10 ? -2 : -4)

        effect.material = .popover
        effect.blendingMode = blending
        effect.state = .active   // 窗口不是焦点时也保持磨砂效果
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.cornerCurve = .continuous
        addSubview(effect)

        tintView.wantsLayer = true
        effect.addSubview(tintView)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let radius = cornerRadius ?? bounds.height / 2
        effect.frame = bounds
        tintView.frame = bounds
        effect.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    private func applyPalette() {
        let palette = WarmPalette(for: self)
        effect.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        tintView.layer?.backgroundColor = palette.tint.cgColor
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = palette.hairline.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 面板上没有控件的地方也吞掉点击（不要穿透到下面的遮罩，否则会误触框选）
    override func mouseDown(with event: NSEvent) {}
}

/// 面板里的细分隔线
final class WarmSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        WarmPalette(for: self).separator.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}

// MARK: - 按钮

/// 悬停高亮的公共逻辑
class WarmControl: NSView {
    var action: (() -> Void)?
    var isEnabled = true { didSet { updateAppearance() } }
    private(set) var isHovered = false
    private(set) var isPressed = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false; updateAppearance() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        updateAppearance()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// 子类根据状态刷新外观
    func updateAppearance() {}

    var palette: WarmPalette { WarmPalette(for: self) }
}

/// 图标按钮（圆角方块）：平时是暖棕色图标，悬停有淡淡的暖色底；选中时是杏色实心 + 白色图标。
/// 一组只能选一个、或各自开关的按钮（标注工具、录屏的声音 / 麦克风 / 指针），选中块由外面一块会流动的杏色液态玻璃代替（见 NativeGlassLens），这里不画
final class ToolbarButton: WarmControl {
    var isSelected = false { didSet { updateAppearance() } }
    /// 一直显示成选中的样子
    var isProminent = false { didSet { updateAppearance() } }
    /// 选中时自己画杏色底。由外面的玻璃标出选中项时关掉（图标照样变白）
    var drawsOwnSelection = true { didSet { updateAppearance() } }
    private let iconView = NSImageView()

    init(symbol: String, help: String) {
        super.init(frame: .zero)
        toolTip = help
        iconView.imageScaling = .scaleNone
        addSubview(iconView)
        setSymbol(symbol)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 点在按钮上任何地方（包括图标）都算按这个按钮
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// 更换图标（开关类按钮在开 / 关时显示不同图标）
    func setSymbol(_ symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config)
        updateAppearance()
    }

    /// 换成自己画的图标（模板图，颜色和系统图标一样跟着按钮状态变）
    func setImage(_ image: NSImage) {
        iconView.image = image
        updateAppearance()
    }

    override func layout() {
        super.layout()
        iconView.frame = bounds
        // 圆角方块，和流动的选中玻璃同一个形状
        layer?.cornerRadius = min(GlassShape.selectionRadius, min(bounds.width, bounds.height) / 2)
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    override func updateAppearance() {
        let filled = isSelected || isProminent
        let background: NSColor = if filled && drawsOwnSelection {
            isPressed ? WarmPalette.accent.blended(withFraction: 0.15, of: .black) ?? WarmPalette.accent : WarmPalette.accent
        } else if isPressed && !filled {
            palette.pressed
        } else if isHovered && isEnabled && !filled {
            palette.hover
        } else {
            .clear
        }
        layer?.backgroundColor = background.cgColor
        iconView.contentTintColor = filled ? .white : (isEnabled ? palette.ink : palette.ink.withAlphaComponent(0.28))
    }
}

/// macOS 26 以前标出选中工具的杏色圆角块（macOS 26 起用会流动的液态玻璃，见 NativeGlassLens），换选中项时这样动：
/// 1. 浮起：一下子变大一圈，边上出现一道亮边和一点影子
/// 2. 滑过去：顺着移动的方向拉长（越快越长），带一点回弹
/// 3. 落下：变回原来的大小，亮边、影子消失
/// 第一次选中时从小一点弹出来，取消选中时缩小淡出。用弹簧物理一帧一帧算（120 帧 / 秒），动完就停，平时不占资源。
@MainActor
final class SlidingSelection {
    /// 放进按钮所在的那一层（在按钮下面）
    let view: NSView
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    // 水平位置（中心）、出现的程度（0 看不见 … 1 完全出现），各自一个弹簧
    private var x: CGFloat = 0, vx: CGFloat = 0, targetX: CGFloat = 0
    private var appear: CGFloat = 0, vAppear: CGFloat = 0, targetAppear: CGFloat = 0
    private var centerY: CGFloat = 0
    private var size = CGSize(width: 32, height: 32)

    init() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = WarmPalette.accent.cgColor
        view.alphaValue = 0
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    /// 移到 rect（按钮的 frame，和透镜同一个坐标）；nil 表示没有选中项（缩小淡出）
    func move(to rect: CGRect?, animated: Bool = true) {
        if let rect {
            size = rect.size
            centerY = rect.midY
            targetX = rect.midX
            targetAppear = 1
            if appear < 0.05 { x = targetX; vx = 0 }   // 从无到有：原地弹出来，不从别处滑过来
        } else {
            targetAppear = 0
        }
        guard animated else {
            x = targetX; vx = 0
            appear = targetAppear; vAppear = 0
            apply()
            return
        }
        start()
    }

    private func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        // 弱引用自己：工具栏关掉、透镜释放了，计时器也跟着停（不会在后台一直跑）
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var dt = min(1.0 / 30, now - lastTick)
        lastTick = now
        // 小步积分，弹簧硬一点也稳
        while dt > 0 {
            let h = min(dt, 1.0 / 240)
            // 位置：稍微欠阻尼，落下时有一点点回弹
            let ax = 330 * (targetX - x) - 27 * vx
            vx += ax * CGFloat(h)
            x += vx * CGFloat(h)
            let aa = 260 * (targetAppear - appear) - 30 * vAppear
            vAppear += aa * CGFloat(h)
            appear += vAppear * CGFloat(h)
            dt -= h
        }
        apply()
        let settled = abs(targetX - x) < 0.25 && abs(vx) < 4 && abs(targetAppear - appear) < 0.005 && abs(vAppear) < 0.05
        if settled {
            x = targetX; vx = 0; appear = targetAppear; vAppear = 0
            apply()
            timer?.invalidate()
            timer = nil
        }
    }

    /// 按现在的位置、速度画出来
    private func apply() {
        // 浮起的程度：跟着速度走（滑得越快浮得越高）
        let lift = min(1, abs(vx) / 520)
        let pop = 0.72 + 0.28 * max(0, appear)   // 弹出 / 收起时的大小
        let width = (size.width * (1 + 0.2 * lift) + min(14, abs(vx) * 0.014)) * pop
        let height = size.height * (1 + 0.12 * lift) * pop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = CGRect(x: x - width / 2, y: centerY - height / 2, width: width, height: height).integral
        view.alphaValue = max(0, min(1, appear))
        // 浮起时：一道亮边 + 一点影子
        view.layer?.borderWidth = lift > 0.02 ? 1 : 0
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.75 * lift).cgColor
        view.layer?.cornerRadius = GlassShape.selectionRadius
        view.layer?.shadowOpacity = Float(0.22 * lift)
        view.layer?.shadowRadius = 6
        CATransaction.commit()
    }
}

/// 胶囊按钮（图标 + 文字）：「完成」杏色、「开始录制」「停止」珊瑚红，白字
final class PillButton: WarmControl {
    var title: String { didSet { needsDisplay = true } }
    var symbol: String { didSet { needsDisplay = true } }
    var color: NSColor { didSet { needsDisplay = true } }

    init(title: String, symbol: String, color: NSColor, help: String) {
        self.title = title
        self.symbol = symbol
        self.color = color
        super.init(frame: .zero)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按内容计算的合适宽度
    var fittingWidth: CGFloat {
        ceil(attributedTitle.size().width) + 16 + 6 + 26
    }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: roundedFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override func updateAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        var fill = color
        if isPressed { fill = color.blended(withFraction: 0.15, of: .black) ?? color }
        else if isHovered { fill = color.blended(withFraction: 0.08, of: .white) ?? color }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: (bounds.height - 2) / 2,
                                 yRadius: (bounds.height - 2) / 2)
        fill.setFill()
        shape.fill()

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white]))
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let text = attributedTitle
        let textSize = text.size()
        let iconSize = icon?.size ?? .zero
        let total = iconSize.width + 6 + textSize.width
        var x = (bounds.width - total) / 2
        icon?.draw(in: CGRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
        x += iconSize.width + 6
        text.draw(at: CGPoint(x: x, y: (bounds.height - textSize.height) / 2))
    }
}

/// 胶囊形分段选择（帧率 30 / 60）
final class SegmentedPill: WarmControl {
    let titles: [String]
    var selectedIndex = 0 {
        didSet {
            needsDisplay = true
            labels.needsDisplay = true
            lens?.select(selectedIndex, animated: lensShown)
            lensShown = true
        }
    }
    var onSelect: ((Int) -> Void)?
    /// 选中的那一段：染成杏色的液态玻璃，换选中项时流过去（macOS 26 起；更早的系统画一块杏色）
    private let lens = NativeGlassLens(cornerRadius: 7)
    private var lensShown = false
    /// 文字单独一层，盖在玻璃上面（不然选中那一段的数字会被玻璃挡住）
    private let labels = OverlayDrawing()

    init(titles: [String], help: String) {
        self.titles = titles
        super.init(frame: .zero)
        toolTip = help
        if let lens { addSubview(lens.view) }
        labels.drawing = { [weak self] in self?.drawTitles() }
        addSubview(labels)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateAppearance() {
        needsDisplay = true
        labels.needsDisplay = true
    }

    override func layout() {
        super.layout()
        labels.frame = bounds
        lens?.setSlots(titles.indices.map(segmentRect), in: bounds)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !titles.isEmpty else { return }
        let index = min(Int(point.x / (bounds.width / CGFloat(titles.count))), titles.count - 1)
        onSelect?(index)
    }

    private var track: CGRect { bounds.insetBy(dx: 2, dy: 4) }

    private func segmentRect(_ index: Int) -> CGRect {
        let track = self.track
        let segmentWidth = track.width / CGFloat(titles.count)
        return CGRect(x: track.minX + CGFloat(index) * segmentWidth, y: track.minY,
                      width: segmentWidth, height: track.height).insetBy(dx: 2, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        palette.hover.setFill()
        NSBezierPath(roundedRect: track, xRadius: GlassShape.selectionRadius, yRadius: GlassShape.selectionRadius).fill()

        if lens == nil {
            // 旧系统：选中是一块杏色的圆角块
            WarmPalette.accent.setFill()
            let segment = segmentRect(selectedIndex)
            NSBezierPath(roundedRect: segment, xRadius: 7, yRadius: 7).fill()
        }
    }

    private func drawTitles() {
        let palette = self.palette
        for (index, title) in titles.enumerated() {
            let segment = segmentRect(index)
            let text = NSAttributedString(string: title, attributes: [
                .font: roundedFont(ofSize: 12, weight: .semibold),
                .foregroundColor: index == selectedIndex ? NSColor.white : palette.ink,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: segment.midX - size.width / 2, y: segment.midY - size.height / 2))
        }
    }
}

/// 不接收鼠标、只按闭包画东西的透明层（叠在别的子视图上面画文字之类）
final class OverlayDrawing: NSView {
    var drawing: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawing?() }
}

// MARK: - 下拉菜单

/// 温暖磨砂风格的下拉菜单（代替系统菜单，外观与工具栏一致）。
/// 显示在所在视图里；点菜单外任何地方、或按 Esc 都会关闭。
final class WarmMenu: NSView {
    struct Item {
        let id: String
        let title: String
        let isSelected: Bool
    }

    private let panel: FrostedPanel
    private let catcher = DismissCatcher()
    private var onSelect: ((String) -> Void)?
    private static let rowHeight: CGFloat = 30
    private static let inset: CGFloat = 6

    /// - Parameters:
    ///   - anchor: 触发按钮在 superview 中的位置；菜单默认出现在它上方（下方放不下时出现在下方）
    @discardableResult
    static func show(items: [Item], in superview: NSView, anchor: CGRect,
                     blending: NSVisualEffectView.BlendingMode, onSelect: @escaping (String) -> Void) -> WarmMenu {
        let menu = WarmMenu(items: items, blending: blending)
        menu.onSelect = onSelect
        menu.catcher.frame = superview.bounds
        menu.catcher.onDismiss = { [weak menu] in menu?.close() }
        superview.addSubview(menu.catcher)
        superview.addSubview(menu)
        let size = menu.frame.size
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        if origin.y + size.height > superview.bounds.maxY - 4 { origin.y = anchor.minY - 8 - size.height }
        origin.x = min(max(origin.x, 4), superview.bounds.maxX - size.width - 4)
        menu.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        return menu
    }

    private init(items: [Item], blending: NSVisualEffectView.BlendingMode) {
        panel = FrostedPanel(cornerRadius: 14, blending: blending)
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = items.map { NSAttributedString(string: $0.title, attributes: [.font: font]).size().width }.max() ?? 100
        let width = max(200, ceil(textWidth) + 52)
        let height = CGFloat(items.count) * Self.rowHeight + Self.inset * 2
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        panel.frame = bounds
        addSubview(panel)
        for (index, item) in items.enumerated() {
            let row = GlassMenuRow(item: item)
            row.frame = CGRect(x: Self.inset, y: height - Self.inset - CGFloat(index + 1) * Self.rowHeight,
                               width: width - Self.inset * 2, height: Self.rowHeight)
            row.action = { [weak self] in
                self?.onSelect?(item.id)
                self?.close()
            }
            panel.addSubview(row)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func close() {
        catcher.removeFromSuperview()
        removeFromSuperview()
    }

    var isOpen: Bool { superview != nil }
}

/// 菜单的一行：左侧勾选（杏色），右侧名称；悬停时圆角高亮
private final class GlassMenuRow: WarmControl {
    private let item: WarmMenu.Item

    init(item: WarmMenu.Item) {
        self.item = item
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        if isHovered {
            (isPressed ? palette.pressed : palette.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        if item.isSelected {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [WarmPalette.accent]))
            if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                check.draw(in: CGRect(x: 10, y: (bounds.height - check.size.height) / 2,
                                      width: check.size.width, height: check.size.height))
            }
        }
        let text = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: item.isSelected ? .semibold : .medium),
            .foregroundColor: palette.ink,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: 32, y: (bounds.height - size.height) / 2))
    }
}

/// 菜单打开时铺在下面的透明层：点到它就关闭菜单（这次点击不会传给下面）
final class DismissCatcher: NSView {
    var onDismiss: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
}
