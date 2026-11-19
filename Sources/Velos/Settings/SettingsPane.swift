import AppKit
import SwiftUI

// 设置窗口的「温暖磨砂」风格（和 2.7 一样，和橙色图标、截图工具栏同一套颜色，见 GlassStyle.swift）：
// - 奶油色的磨砂底，角落里两团柔和的杏色、珊瑚色光晕；圆角卡片；圆润字体；暖色的图标小方块
// - 选中块（侧栏、分段选择）是染成杏色的液态玻璃，换位置时像液体一样流过去；开关的小圆块是透明的玻璃
// - 每行左边标题、右边控件，不写说明文字（看不懂就改布局）
// 注意：只装了命令行工具时没有 SwiftUI 的宏插件，不能用 @State，界面状态一律放在 ObservableObject 里。

// MARK: - 配色

/// 设置窗口、翻译结果窗口（SwiftUI）的配色。主色 accent（杏色）、hot（珊瑚红）取自 GlassPalette；
/// 文字、细线等按 SwiftUI 窗口的底色单独调过，和 GlassPalette 里的同名颜色数值略有不同，改动时两边一起看
extension Color {
    private static func warm(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 杏色：选中、开关开着、主按钮
    static let accent = Color(nsColor: GlassPalette.accent)
    /// 珊瑚红：录屏、未授权
    static let hot = Color(nsColor: GlassPalette.hot)
    /// 文字和图标（暖棕 / 奶白）
    static let ink = warm(light: GlassPalette.deepInk, dark: NSColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 1))
    static let inkSecondary = warm(light: GlassPalette.deepInk.withAlphaComponent(0.58),
                                   dark: NSColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 0.55))
    /// 卡片底色
    static let settingsCard = warm(light: NSColor(srgbRed: 1, green: 0.99, blue: 0.975, alpha: 0.72),
                                   dark: NSColor(srgbRed: 0.30, green: 0.24, blue: 0.20, alpha: 0.55))
    /// 卡片里的分隔线、卡片的细边
    static let hairline = warm(light: NSColor(srgbRed: 0.45, green: 0.33, blue: 0.22, alpha: 0.13),
                               dark: NSColor(srgbRed: 1, green: 0.9, blue: 0.8, alpha: 0.12))
    /// 关着的开关、分段选择的轨道、悬停的底色
    static let glassTrack = warm(light: NSColor(srgbRed: 0.45, green: 0.33, blue: 0.22, alpha: 0.12),
                                 dark: NSColor(srgbRed: 1, green: 0.9, blue: 0.8, alpha: 0.13))
    /// 窗口底色上叠的奶油色渐变
    static let warmWashTop = warm(light: NSColor(srgbRed: 1, green: 0.95, blue: 0.89, alpha: 0.78),
                                  dark: NSColor(srgbRed: 0.22, green: 0.17, blue: 0.14, alpha: 0.72))
    static let warmWashBottom = warm(light: NSColor(srgbRed: 0.99, green: 0.91, blue: 0.84, alpha: 0.7),
                                     dark: NSColor(srgbRed: 0.18, green: 0.14, blue: 0.12, alpha: 0.78))

    // 图标小方块的几种暖色
    static let chipHoney = Color(red: 0.95, green: 0.68, blue: 0.25)
    static let chipSage = Color(red: 0.45, green: 0.70, blue: 0.47)
    static let chipSky = Color(red: 0.38, green: 0.62, blue: 0.88)
    static let chipLavender = Color(red: 0.62, green: 0.52, blue: 0.85)
    static let chipCocoa = Color(red: 0.62, green: 0.45, blue: 0.34)
}

// MARK: - 液态玻璃

/// 选中块：系统原生的液态玻璃，换位置时像液体一样流过去，和标注工具栏的选中玻璃（NativeGlassLens）同一套做法、同样的动作：
/// 同一个玻璃容器里两块玻璃，「头」快、「尾」慢；停着时重合成一块，移动时头尾拉开，系统把它们画成一滴被拉长、拉丝、再合上的液体。
/// tint 给玻璃染色（侧栏、分段选择是杏色；开关的小圆块不染）：玻璃下面垫一块同样跟着走的杏色，
/// 不只靠玻璃自带的 tint——它在窗口不在最前面时会被系统褪成灰色，白字就看不清了。
/// macOS 26 以前只有那块杏色，用弹簧滑过去。
struct LiquidSelection: View {
    /// 选中块的位置（在这一层里的坐标）
    let rect: CGRect
    var cornerRadius: CGFloat = GlassShape.selectionRadius
    var tint: Color? = .accent

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let tint {
                base(tint, GlassShape.tail)
                base(tint, GlassShape.head)
            }
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: GlassShape.spacing) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        drop(GlassShape.tail)
                        drop(GlassShape.head)
                    }
                }
            } else if tint == nil {
                place(shape.fill(Color.white).shadow(color: .black.opacity(0.15), radius: 2, y: 1), GlassShape.head)
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    /// 垫在玻璃下面的颜色（和玻璃一起走）
    private func base(_ color: Color, _ animation: Animation) -> some View {
        place(shape.fill(LinearGradient(colors: [color.opacity(0.88), color], startPoint: .top, endPoint: .bottom))
                .shadow(color: color.opacity(0.4), radius: 4, y: 2), animation)
    }

    @available(macOS 26, *)
    private func drop(_ animation: Animation) -> some View {
        // 下面垫了杏色时用更透的玻璃（.clear），杏色才鲜亮；开关的小圆块下面没垫颜色，用普通玻璃
        place(Color.clear.glassEffect((tint == nil ? Glass.regular : Glass.clear).tint(tint).interactive(), in: shape), animation)
    }

    private func place(_ view: some View, _ animation: Animation) -> some View {
        view
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .animation(animation, value: rect)
    }
}

// MARK: - 面板骨架

/// 所有设置面板的统一外观：一列分组卡片，放在设置窗口右侧（可滚动）
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 24)
    }
}

/// 一组设置：小标题 + 奶白圆角卡片。行与行之间的分隔线自动画（第一行上面不画）
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.inkSecondary)
                .padding(.leading, 8)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            // 1 点宽：在 1x 屏上也对齐像素，不会时有时无
                            Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 13)
                        }
                        row
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.settingsCard)
                    .shadow(color: Color(red: 0.35, green: 0.2, blue: 0.1).opacity(0.07), radius: 8, y: 2)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
        }
    }
}

/// 卡片里的一行：左边标题，右边控件。caption 只用来显示状态或出错原因，不写说明
struct SettingsRow<Accessory: View>: View {
    let title: String
    var caption: String? = nil
    /// 从属于上一行的选项：往里缩一点
    var indented = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.ink)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.leading, indented ? 30 : 14)
        .padding(.trailing, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

/// 图标小方块：暖色渐变的圆角方块 + 白色图标（侧栏用）
struct IconChip: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .top, endPoint: .bottom))
            .overlay(Glyph(symbol, size: side * 0.48).foregroundStyle(.white))
            .frame(width: side, height: side)
            .shadow(color: tint.opacity(0.35), radius: 2.5, y: 1)
    }
}

// MARK: - 控件

/// 开关：关着是浅浅的暖灰、开着是杏色；上面的小圆块是透明的液态玻璃，拨动时像液体一样流到另一头（和侧栏、分段选择同一套动作）
struct GlassSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassSwitch(isOn: configuration.$isOn)
    }
}

private struct GlassSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    private static let size = CGSize(width: 38, height: 22)
    /// 小圆块：比轨道矮一点、宽一点（胶囊形），留 2 点边
    private static let knob = CGSize(width: 22, height: 18)
    private static let inset: CGFloat = 2

    var body: some View {
        let size = Self.size, knob = Self.knob, inset = Self.inset
        Button { isOn.toggle() } label: {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Color.accent.opacity(0.85), .accent],
                                                              startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(Color.glassTrack))
                    .frame(width: size.width, height: size.height)
                    .animation(.easeOut(duration: 0.2), value: isOn)
                LiquidSelection(rect: CGRect(x: isOn ? size.width - inset - knob.width : inset, y: inset,
                                             width: knob.width, height: knob.height),
                                cornerRadius: knob.height / 2, tint: nil)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// 一行里只有开关
struct SwitchRow: View {
    let title: String
    var caption: String? = nil
    var indented = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption, indented: indented) {
            Toggle("", isOn: $isOn).toggleStyle(GlassSwitchStyle()).labelsHidden()
        }
    }
}

/// 分段选择：暖灰的胶囊轨道上，选中的那一段是杏色的液态玻璃，换选项时像液体一样流过去（和侧栏、标注工具栏同一套）
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// 每一段的宽度（让同一页里的分段控件对齐）
    var segmentWidth: CGFloat = 62

    @Environment(\.isEnabled) private var isEnabled
    private let height: CGFloat = 26
    /// 玻璃和轨道边缘之间留的空
    private let inset: CGFloat = 2

    var body: some View {
        let index = CGFloat(options.firstIndex { $0.value == selection } ?? 0)
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.glassTrack)
            LiquidSelection(rect: CGRect(x: index * segmentWidth + inset, y: inset,
                                         width: segmentWidth - inset * 2, height: height - inset * 2),
                            cornerRadius: (height - inset * 2) / 2)
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    let selected = options[i].value == selection
                    Button { selection = options[i].value } label: {
                        Text(options[i].title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(selected ? Color.white : Color.ink)
                            .lineLimit(1)
                            .frame(width: segmentWidth, height: height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(width: segmentWidth * CGFloat(options.count), height: height)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 胶囊按钮；prominent 为杏色实心
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(prominent ? Color.white : Color.ink)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accent) : AnyShapeStyle(Color.glassTrack)))
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: prominent ? 0 : 0.5))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// 状态小徽章：小圆点 + 文字（绿色正常、珊瑚色有问题）
struct StatusBadge: View {
    let ok: Bool
    let text: String

    var body: some View {
        let color = ok ? Color.chipSage : Color.hot
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 2.5)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

// MARK: - 窗口背景

/// 窗口背景：系统毛玻璃 + 奶油色渐变 + 角落里两团柔和的杏色、珊瑚色光晕（设置窗口、翻译结果窗口共用）
struct WarmWindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [.warmWashTop, .warmWashBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                Circle()
                    .fill(Color.accent.opacity(0.22))
                    .frame(width: 260, height: 260)
                    .blur(radius: 70)
                    .position(x: proxy.size.width - 40, y: 20)
                Circle()
                    .fill(Color.hot.opacity(0.10))
                    .frame(width: 220, height: 220)
                    .blur(radius: 70)
                    .position(x: 30, y: proxy.size.height - 10)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 系统毛玻璃（一直保持磨砂，窗口不在最前面时也不变成实心）
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
