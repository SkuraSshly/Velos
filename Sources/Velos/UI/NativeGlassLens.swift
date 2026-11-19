import AppKit
import SwiftUI

/// 一排按钮里标出选中项的玻璃，用系统原生的液态玻璃（macOS 26 起），染成杏色（按钮上的图标变白）。
///
/// 流动感的来源：同一个 GlassEffectContainer 里的几块玻璃靠近时，系统会把它们画成连在一起的一滴液体
/// （中间拉丝、离远了分开、靠近又合上，边缘带折射），这是系统渲染的，不是我们自己画的。
///
/// 两种用法：
/// - 只能选一个（标注工具、帧率）：`select(_:animated:)`。放两块一样的玻璃，「头」用快的弹簧先冲过去，
///   「尾」用慢一点的弹簧跟上；停着时完全重合看起来是一块，切换时头尾拉开，系统就画成一滴被拉长、流过去的液体。
/// - 各自开关（录屏的声音、麦克风、指针）：`setOn(_:animated:)`。每个位置一块玻璃，打开时从中间一点「涌」出来，
///   关掉时缩回去；挨着的两个都开着时，系统会把它们连成一整块。
///
/// 这一层只画玻璃、不接收鼠标，垫在 AppKit 的按钮下面；按钮照常处理点击。更早的系统返回 nil，由调用方用旧的样子代替。
@MainActor
final class NativeGlassLens {
    let view: NSView
    private let model: LensModel

    /// - Parameters:
    ///   - cornerRadius: 玻璃的圆角（圆角长方形，和按钮的形状一致）
    ///   - spacing: 两块玻璃离多近就连成一滴（越大拉丝越长、越不容易断开）
    ///   - tint: 玻璃染的颜色
    init?(cornerRadius: CGFloat = GlassShape.selectionRadius, spacing: CGFloat = GlassShape.spacing,
          tint: NSColor = GlassPalette.accent) {
        guard #available(macOS 26, *) else { return nil }
        model = LensModel(cornerRadius: cornerRadius, spacing: spacing, tint: Color(nsColor: tint))
        let host = PassThroughHostingView(rootView: AnyView(LensRow(model: model)))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        view = host
    }

    /// 告诉它各个按钮的位置（AppKit 坐标，原点在左下角，和这一层同一个坐标系）
    func setSlots(_ frames: [CGRect], in bounds: CGRect) {
        view.frame = bounds
        // 换成 SwiftUI 的坐标（原点在左上角）
        let slots = frames.map { CGRect(x: $0.minX, y: bounds.height - $0.maxY, width: $0.width, height: $0.height) }
        if slots != model.slots { model.slots = slots }
    }

    /// 只能选一个：选中第几个（nil 表示都不选）
    func select(_ index: Int?, animated: Bool) {
        guard index != model.selected else { return }
        model.animates = animated
        model.selected = index
    }

    /// 各自开关：哪几个是开着的
    func setOn(_ indices: Set<Int>, animated: Bool) {
        guard indices != model.on else { return }
        model.animates = animated
        model.on = indices
    }
}

/// 选中玻璃的形状和动作（标注工具栏、录屏选项条、设置侧栏共用一套）
enum GlassShape {
    /// 圆角长方形，和工具栏按钮的悬停底色一样
    static let selectionRadius: CGFloat = 9
    /// 两块玻璃离多近就连成一滴
    static let spacing: CGFloat = 36
    /// 头：快、带一点回弹；尾：慢一些、更软。两者差得越多，拉得越长
    static let head = Animation.spring(response: 0.3, dampingFraction: 0.68)
    static let tail = Animation.spring(response: 0.52, dampingFraction: 0.8)
}

@MainActor
private final class LensModel: ObservableObject {
    let cornerRadius: CGFloat
    let spacing: CGFloat
    let tint: Color
    @Published var slots: [CGRect] = []
    @Published var selected: Int?
    @Published var on: Set<Int> = []
    /// 这次变化要不要动画（第一次放好时不要）
    var animates = false

    init(cornerRadius: CGFloat, spacing: CGFloat, tint: Color) {
        self.cornerRadius = cornerRadius
        self.spacing = spacing
        self.tint = tint
    }
}

private struct LensRow: View {
    @ObservedObject var model: LensModel

    /// 开关：涌出来时带回弹
    private static let toggle = Animation.spring(response: 0.38, dampingFraction: 0.62)

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: model.spacing) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if let slot = selectedSlot {
                        glass(slot, animation: GlassShape.tail, value: model.selected)
                        glass(slot, animation: GlassShape.head, value: model.selected)
                    }
                    ForEach(model.slots.indices, id: \.self) { index in
                        let isOn = model.on.contains(index)
                        // 关着时缩成中间的一个点（看不见），打开时涌到整个按钮大小
                        glass(isOn ? model.slots[index] : CGRect(origin: CGPoint(x: model.slots[index].midX, y: model.slots[index].midY), size: .zero),
                              animation: Self.toggle, value: isOn)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var selectedSlot: CGRect? {
        guard let index = model.selected, model.slots.indices.contains(index) else { return nil }
        return model.slots[index]
    }

    @available(macOS 26, *)
    private func glass<V: Equatable>(_ rect: CGRect, animation: Animation, value: V) -> some View {
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .glassEffect(.regular.tint(model.tint).interactive(), in: RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous))
            .offset(x: rect.minX, y: rect.minY)
            .animation(model.animates ? animation : nil, value: value)
    }
}

/// 不接收鼠标的 SwiftUI 宿主：点击直接落到上面的按钮（或者下面的面板）
private final class PassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}
