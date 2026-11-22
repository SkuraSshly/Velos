// 晾衣绳的界面移植自 Tendedero（https://github.com/alejandrobujan/tendedero）的 LineView、PeggedView，
// 以及它的修改分支 Picline（https://github.com/Xinguangcuican/Picline）的大小、保留数量、拖入时的落点。
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 改动：去掉了搜索、文字便签；选中只在右上角打勾；夹子是 Velos 的杏色；文字改成中文。

import SwiftUI

/// 绳子和卡片的尺寸（点）。照片的大小跟着设置里的「小 / 中 / 大」变，夹子、绳子、玻璃框不变
enum ClotheslineLayout {
    nonisolated static var size: ClotheslineSize {
        ClotheslineSize(rawValue: AppIdentity.defaults.string(forKey: "clotheslineSize") ?? "") ?? .medium
    }
    /// 保留几张：0 是「屏幕放得下几张就几张」，否则是 25 / 50 / 100（多出来的滚动着看）
    nonisolated static var keep: Int { AppIdentity.defaults.integer(forKey: "clotheslineKeep") }
    nonisolated static let keepChoices = [0, 25, 50, 100]

    nonisolated static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    nonisolated static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    nonisolated static var spacing: CGFloat { cardWidth + 24 }
    nonisolated static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// 绳子从屏幕一边垂到另一边，中间往下坠一点（抛物线）
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// 这么宽的屏幕一次放得下几张（3 ~ 12 张）
    nonisolated static func capacity(width: CGFloat) -> Int { max(3, min(12, Int((width - 200) / spacing))) }

    /// 钉住的照片在能滚动的绳子上留在左头不动（钉住的太多、几乎占满时就不留，一起滚）
    static func anchorsPinned(_ pinned: Int, visible: Int) -> Bool {
        pinned > 0 && pinned < visible - 1
    }

    /// 能滚动、钉住的留在左头时：后面滚过来的照片在这里之前淡出
    static func pinnedEdge(count: Int, width: CGFloat, visible: Int, pinned: Int) -> CGFloat? {
        guard keep > 0, count > visible, anchorsPinned(pinned, visible: visible) else { return nil }
        let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
        return newest - CGFloat(visible - pinned) * spacing
    }

    /// 照片间隔 spacing 居中挂。多于放得下的：保留数量设成 25 / 50 / 100 时间隔不变，最新的停在满绳时最后一张的位置，
    /// 往左滚动（scroll）看更早的；否则（挂在更宽的屏幕上）挤近一点，不超出屏幕。
    /// 前 pinned 张是钉住的：能滚动时留在左头不动，其余在它们后面滚
    /// 量卡片位置用的坐标（绳子挂好时和窗口坐标一样，左上角为原点）
    static let space = "clothesline"

    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat, pinned: Int = 0) -> CGFloat {
        if keep > 0 && count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            if anchorsPinned(pinned, visible: visible), index < pinned {
                return newest - CGFloat(visible - 1 - index) * spacing
            }
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct ClotheslineView: View {
    @ObservedObject var model: ClotheslineModel

    private var items: [ClotheslineItem] { model.items }
    private var pinned: Int { model.pinnedLead }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                // 空绳子：一句提示；第一次使用：多写一句怎么把绳子叫下来（有照片时写在照片下面）
                if let coaching = model.coachingText {
                    Text(coaching)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: width / 2, y: items.isEmpty ? ClotheslineLayout.ropeY(x: width / 2, width: width) + 40
                                                                 : ClotheslineLayout.panelHeight + 18)
                        .transition(.opacity)
                } else if items.isEmpty && !model.catching {
                    Text("截一张图，它就会挂在这里")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: width / 2, y: ClotheslineLayout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                if let x = knotX(width: width) {
                    Knot()
                        .position(x: x, y: ClotheslineLayout.ropeY(x: x, width: width) + 0.5)
                        .transition(.opacity)
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let x = ClotheslineLayout.x(index: index, count: items.count, width: width,
                                                visible: model.visibleCount, scroll: model.scroll, pinned: pinned)
                    // 能滚动的绳子：照片碰到屏幕边、或滑到钉住的那几张后面时变淡、不能点
                    let bounds = index >= pinned ? scrollBounds(width: width) : nil
                    let cardLeft = x - ClotheslineLayout.cardWidth / 2, cardRight = x + ClotheslineLayout.cardWidth / 2
                    let out = bounds.map { cardLeft < $0.lowerBound || cardRight > $0.upperBound } == true
                    let fadeIn = bounds.map { bounds -> CGFloat in
                        let gone = bounds.lowerBound - ClotheslineLayout.cardWidth / 2
                        let rest = firstLooseX(width: width) - ClotheslineLayout.cardWidth / 2
                        return min(1, max(0, (cardLeft - gone) / max(1, rest - gone)))
                    } ?? 1
                    let ropeY = ClotheslineLayout.ropeY(x: x, width: width)
                    PeggedView(item: item, model: model)
                        .frame(width: ClotheslineLayout.cardWidth, height: ClotheslineLayout.panelHeight - ropeY, alignment: .top)
                        .opacity(min(1, max(0, min(x, width - x) / 90)) * fadeIn
                                 * (bounds.map { cardRight > $0.upperBound } == true ? 0.35 : 1))
                        .animation(.easeOut(duration: 0.2), value: out)
                        .allowsHitTesting(!out)
                        .zIndex(index < pinned ? 1 : 0)
                        // 挂上来：从上面落下；拿走（拖走、取下）：缩小淡出
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -30)),
                                                removal: .scale(scale: 0.4, anchor: .top).combined(with: .opacity)))
                        .position(x: x, y: ropeY - ClotheslineLayout.pinAbove + (ClotheslineLayout.panelHeight - ropeY) / 2)
                }

                // 拖着图片过来：最右边空出一个虚线框，松手就挂在这里
                if model.catching {
                    let x = catchX(width: width)
                    let ropeY = ClotheslineLayout.ropeY(x: x, width: width)
                    CatchSlot()
                        .frame(width: ClotheslineLayout.cardWidth - 14, height: ClotheslineLayout.photoMaxHeight)
                        .position(x: x, y: ropeY + 8 + ClotheslineLayout.photoMaxHeight / 2)
                        .transition(.opacity)
                }
            }
            // 卡片的位置在这个坐标里量：不跟着绳子滑下来 / 收上去的那段动画走，量到的始终是挂好时的位置
            // （截图飞过来时绳子还在往下滑，量窗口坐标会量到半空中，飞过头）
            .coordinateSpace(name: ClotheslineLayout.space)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: items.map(\.id))
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: items.map(\.pinned))
            .animation(.easeInOut(duration: 0.3), value: items.isEmpty)
            .animation(.easeOut(duration: 0.18), value: model.catching)
            // 收起时整条绳子藏在屏幕顶上，从菜单栏下面滑出来，就像自动隐藏的程序坞
            .offset(y: model.revealed ? 0 : -(ClotheslineLayout.panelHeight + 12))
            .animation(model.revealed ? .spring(response: 0.42, dampingFraction: 0.82) : .easeIn(duration: 0.22),
                       value: model.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            MainActor.assumeIsolated { model.hitRects = rects }
        }
    }

    /// 拖进来的图会挂在哪：最新那张的右边
    private func catchX(width: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return width / 2 }
        let last = ClotheslineLayout.x(index: items.count - 1, count: items.count, width: width,
                                       visible: model.visibleCount, scroll: 0, pinned: pinned)
        return min(width - ClotheslineLayout.cardWidth / 2 - 20, last + ClotheslineLayout.spacing)
    }

    /// 能滚动的绳子上，钉住的后面第一张不动时在哪
    private func firstLooseX(width: CGFloat) -> CGFloat {
        let visible = model.visibleCount
        let newest = width / 2 + CGFloat(visible - 1) * ClotheslineLayout.spacing / 2
        let first = newest - CGFloat(visible - 1) * ClotheslineLayout.spacing
        let lead = ClotheslineLayout.anchorsPinned(pinned, visible: visible) ? pinned : 0
        return first + CGFloat(lead) * ClotheslineLayout.spacing
    }

    /// 能滚动的绳子上照片从哪到哪算完整露出来：钉住的留在左头时从结那里算，否则从屏幕左边；右边是屏幕右边。不能滚动时为 nil
    private func scrollBounds(width: CGFloat) -> ClosedRange<CGFloat>? {
        guard ClotheslineLayout.keep > 0, items.count > model.visibleCount else { return nil }
        let pinnedStay = ClotheslineLayout.pinnedEdge(count: items.count, width: width,
                                                      visible: model.visibleCount, pinned: pinned) != nil
        let start = pinnedStay ? knotX(width: width) ?? 0 : 0
        return start...width
    }

    /// 绳结：钉住的那几张右边打一个结，结左边的都是钉住的
    private func knotX(width: CGFloat) -> CGFloat? {
        guard pinned > 0 else { return nil }
        let last = pinned - 1
        let x = { (i: Int) in ClotheslineLayout.x(index: i, count: items.count, width: width,
                                                  visible: model.visibleCount, scroll: model.scroll, pinned: pinned) }
        if ClotheslineLayout.pinnedEdge(count: items.count, width: width, visible: model.visibleCount, pinned: pinned) != nil {
            return x(last) + ClotheslineLayout.spacing / 2
        }
        let next = last + 1 < items.count ? x(last + 1) : x(last) + ClotheslineLayout.spacing
        return (x(last) + next) / 2
    }
}

/// 绳结：结左边挂着的都是钉住的
private struct Knot: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(white: 0.5))
                .frame(width: 7, height: 5.5)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            Path { p in
                p.move(to: CGPoint(x: 3.5, y: 3))
                p.addQuadCurve(to: CGPoint(x: 1.5, y: 11), control: CGPoint(x: 3.8, y: 7))
                p.move(to: CGPoint(x: 4, y: 3))
                p.addQuadCurve(to: CGPoint(x: 6.5, y: 10), control: CGPoint(x: 4.5, y: 7))
            }
            .stroke(Color(white: 0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(width: 8, height: 12)
            .offset(y: 5)
        }
        .allowsHitTesting(false)
    }
}

/// 拖着图片过来时的落点：虚线框 + 「松手挂上」
private struct CatchSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: CardFrame.radius - CardFrame.inset, style: .continuous)
            .strokeBorder(Color(nsColor: WarmPalette.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CardFrame.radius - CardFrame.inset, style: .continuous))
            .overlay(
                Text("松手挂上")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            )
            .allowsHitTesting(false)
    }
}

/// 一张照片和它的夹子：挂上去时荡一下，有风时轻轻晃
struct PeggedView: View {
    let item: ClotheslineItem
    @ObservedObject var model: ClotheslineModel

    /// 卡片自己的动画状态（命令行工具没有 SwiftUI 的宏插件，不能用 @State，改用一个小的 ObservableObject）
    @StateObject private var motion = CardMotion()
    private var swing: Double { motion.swing }
    private var arrived: Bool { motion.arrived }
    private var hovering: Bool { motion.hovering }

    private var copied: Bool { model.doneIDs.contains(item.id) }
    private var selected: Bool { model.selectedIDs.contains(item.id) }
    private var dragging: Bool { model.draggingID == item.id }
    /// 浮起来：鼠标停在上面，或正被拖着（拖的时候鼠标已经不在卡片上，但不要因此缩回去）
    private var lifted: Bool { hovering || dragging }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin(pinned: item.pinned).zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // 截图还在飞过来：先藏着，飞到了直接出现（飞过来的那张和它一模一样，正好盖在上面，再在上面淡掉）
        .opacity(arrived && model.flyingID != item.id ? 1 : 0)
        .transaction { if model.flyingID == item.id { $0.animation = nil } }
        .onChange(of: model.flyingID == item.id) { was, now in if was && !now { land() } }
        .onAppear(perform: arrive)
        .onChange(of: model.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    /// 照片按比例放进卡片，宽图、长图都贴着边框
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = ClotheslineLayout.cardWidth - 14, maxH = ClotheslineLayout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var photoSize: CGSize { Self.photoSize(for: item.thumb.size) }

    private var card: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width, height: photoSize.height)
            // 同心圆角：照片的圆角 = 框的圆角 − 内边距
            .clipShape(RoundedRectangle(cornerRadius: CardFrame.radius - CardFrame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CardFrame.radius - CardFrame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                // 录屏：第一帧上一个播放按钮；GIF：标一个「GIF」；正在导出 GIF：显示进度
                if let progress = model.gifProgress[item.id] {
                    Text("正在生成 GIF \(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .allowsHitTesting(false)
                } else if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                } else if item.isGIF {
                    Text("GIF")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassFrame(capsule: true)
                        .allowsHitTesting(false)
                }
            }
            .padding(CardFrame.inset)
            .glassFrame(cornerRadius: CardFrame.radius)
            // 选中只在右上角打个勾（不加边框）
            .overlay(alignment: .bottom) {
                // 选中：下边中间打个勾（四个角是按钮）
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(nsColor: WarmPalette.accent))
                        .font(.system(size: 17, weight: .semibold))
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
            // 鼠标停在上面：稍微浮起来。按下、开始拖时大小不变（不再缩一下又弹回来，那样看着像闪了两下），
            // 拖走时只平滑地变淡一次，表示它被拿起来了
            .shadow(color: .black.opacity(lifted ? 0.26 : 0.18), radius: lifted ? 14 : 10, y: lifted ? 8 : 5)
            .scaleEffect(lifted ? 1.035 : 1, anchor: .top)
            .opacity(dragging ? 0.45 : 1)
            .animation(.easeOut(duration: 0.2), value: dragging)
            .overlay {
                // 卡片上的按钮：画在这里，点击由盖在上面的 GrabView 按同样的位置处理（见 CardButton）
                GeometryReader { geo in
                    ForEach(CardButton.shown(for: item, saved: model.savedIDs.contains(item.id)), id: \.self) { button in
                        let frame = button.frame(in: geo.size)
                        let on = button == .pinOnLine && item.pinned
                        Group {
                            if button == .exportGIF {
                                Text("GIF").font(.system(size: 9, weight: .heavy, design: .rounded))
                            } else {
                                Image(systemName: button.symbol)
                                    .font(.system(size: button == .remove ? 11 : 13, weight: .bold))
                            }
                        }
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(width: frame.width, height: frame.height)
                        .background(on ? Circle().fill(Color(nsColor: WarmPalette.accent)) : nil)
                        .glassFrame(circle: true)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(hovering && !dragging && model.gifProgress[item.id] == nil ? 1 : 0)
                        .scaleEffect(hovering ? 1 : 0.6)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(ClotheslineGrabArea(item: item, model: model, saved: model.savedIDs.contains(item.id)))
            .overlay(alignment: .bottom) {
                if copied {
                    Label(model.doneText, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { motion.hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self, value: [item.id: g.frame(in: .named(ClotheslineLayout.space))])
                }
            )
    }

    private func arrive() {
        // 飞过来的那张：飞的过程中它先静止挂好，飞的图正好落在它上面（晃着的话落下时对不上）；落下后自己晃一下
        if model.flyingID == item.id {
            motion.swing = 0
            motion.arrived = true
            return
        }
        motion.swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { motion.arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { motion.swing = 0 }
    }

    /// 飞到了：不跳，从静止轻轻晃一下（和 Picline 一样 2.2°）
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        guard model.flyingID != item.id else { return }   // 还在飞过来的那张不晃，落下时才对得上
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard model.revealed else { return }
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        guard model.revealed else { return }
        withAnimation(.easeOut(duration: 0.3)) { motion.swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { motion.swing = 0 }
        }
    }
}

/// 一张卡片的晃动、出现、悬停状态
@MainActor
final class CardMotion: ObservableObject {
    @Published var swing: Double = 0
    @Published var arrived = false
    @Published var hovering = false
}

enum CardFrame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// 晾衣绳卡片（和卡片上的按钮、飞过来的那张）的玻璃：静止的透明玻璃——薄薄一层磨砂 + 上亮下淡的清楚亮边。
    /// 不用系统的液态玻璃：卡片一直在晃、在飞、被拖动，液态玻璃会跟着不停地折射、流动，
    /// 靠得近的几块还会融到一起，看着像在冒泡；静止的玻璃动起来也是干净的
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// 夹子：杏色的小金属夹，夹住绳子的地方有一道缝；钉住的是深灰色（一眼看出哪些不会被挤掉）
struct Clothespin: View {
    var pinned = false

    private let spaceGrey = LinearGradient(
        stops: [
            .init(color: Color(white: 0.30), location: 0),
            .init(color: Color(white: 0.47), location: 0.35),
            .init(color: Color(white: 0.38), location: 0.65),
            .init(color: Color(white: 0.24), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    private let metal = LinearGradient(
        stops: [
            // 铝色的夹子（像 Mac 的机身）
            .init(color: Color(red: 0.93, green: 0.70, blue: 0.52), location: 0),
            .init(color: Color(red: 1.00, green: 0.88, blue: 0.76), location: 0.35),
            .init(color: Color(red: 0.96, green: 0.78, blue: 0.62), location: 0.65),
            .init(color: Color(red: 0.85, green: 0.60, blue: 0.43), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(pinned ? spaceGrey : metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.32)).frame(width: 5, height: 1.4).padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}

/// 一根细细的中灰色绳子：浅色、深色背景上都看得清；两头淡出，像是从屏幕外面拉过来的
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = ClotheslineLayout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(to: CGPoint(x: width + 20, y: top),
                           control: CGPoint(x: width / 2, y: top + 2 * ClotheslineLayout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
