// 截图飞到绳上的动画照 Tendedero（App：https://github.com/alejandrobujan/tendedero 的 CaptureFlight；
// 网站：https://tendedero.app 的 js/line.js 里的 fly），Copyright (c) 2026 Alejandro Buján，MIT 许可证
// （全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 时长、曲线、弧度、圆角和边框怎么长出来都和网站一样；画面用 Velos 卡片自己的玻璃框和夹子，落下时和真卡片一模一样。

import AppKit
import SwiftUI

/// 截图（录屏）飞到晾衣绳上的那一下。
///
/// 1. 截完：截下来的图原样停在原位（截整个屏幕时全屏闪一下白），等绳子放下来、新卡片排好位置
/// 2. 飞：0.65 秒，先慢后快再慢（easeInOutCubic），往上拱一点（最高 30 点）；
///    一边飞一边变成卡片的大小，照片四周长出卡片的玻璃框、圆角，后半程夹子和框淡入，同时转到卡片挂着的角度
/// 3. 到了：真卡片出现，飞的这张在上面 0.16 秒淡掉，卡片轻轻晃一下
///
/// 用一块和屏幕一样大的透明窗口当画布（不接收鼠标），每一帧按进度画（SwiftUI 的 TimelineView，跟着屏幕刷新）。
@MainActor
final class ClotheslineFlight {
    private let window: NSPanel
    private let screen: NSScreen
    private let state: FlightState

    /// 最长在屏幕上停多久：不管发生什么（没写进去、绳子没放下来、动画没回调），到点一定收掉，绝不会一直停在屏幕上
    private static let maxLifetime: TimeInterval = 6
    /// 飞多久（和网站一样）
    static let duration: TimeInterval = 0.65
    private var finished = false
    /// 飞完、收掉窗口之前自己拉着自己：不然没人拿着它时会被提前释放，窗口就再也没人关，图一直停在屏幕上（还点不到）
    private var keepAlive: ClotheslineFlight?

    /// - Parameters:
    ///   - image: 截下来的图
    ///   - rect: 截图的位置（全局坐标）；不在屏幕上时从屏幕中间出来
    init?(image: CGImage, from rect: CGRect) {
        guard let screen = NSScreen.screen(containing: CGPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main else { return nil }
        self.screen = screen
        var start = rect.intersection(screen.frame)
        if start.isNull || start.width < 4 || start.height < 4 {
            let width: CGFloat = 260
            let height = width * CGFloat(image.height) / CGFloat(max(image.width, 1))
            start = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2, width: width, height: height)
        }
        // 截了整个屏幕：全屏闪一下白（网站上也是只有截整个屏幕时才闪）
        let wholeScreen = start.width >= screen.frame.width - 2 && start.height >= screen.frame.height - 2
        state = FlightState(image: NSImage(cgImage: image, size: start.size), from: Self.local(start, in: screen),
                            flashes: wholeScreen)
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let host = NSHostingView(rootView: FlightView(state: state))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView = host
    }

    /// 全局坐标（原点在左下角）→ 画布里的坐标（原点在左上角，和 SwiftUI 一样）
    private static func local(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - 1. 截完

    /// 截下来的图出现在原位（和屏幕上一模一样，看不出来），截整个屏幕时闪一下白
    func show() {
        guard keepAlive == nil, !finished else { return }   // 已经在屏幕上了
        keepAlive = self
        window.orderFrontRegardless()
        if state.flashes { state.flashStart = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLifetime) { [self] in
            guard !finished else { return }
            Log.capture.notice("晾衣绳：飞的截图超时，收掉")
            fadeAway()
        }
    }

    // MARK: - 2. 飞过去

    /// 飞到 target（全局坐标，卡片本身的位置：玻璃框的外沿，不算歪），落下后调用 landed
    /// - Parameter tilt: 卡片挂着歪的角度（度，顺时针为正）：飞到时也歪成一样，接上真卡片不会跳一下
    func fly(to target: CGRect, tilt: Double, landed: @escaping () -> Void) {
        state.to = Self.local(target, in: screen)
        state.tilt = tilt
        state.flyStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [self] in
            guard !finished else { return }
            landed()
            // 真卡片已经在下面出现：这张在上面淡掉
            fadeAway(duration: 0.16)
        }
    }

    /// 飞的途中卡片又挪了（旁边的卡片让位、绳子还在往下滑）：改飞到新的位置
    func retarget(_ target: CGRect) {
        let local = Self.local(target, in: screen)
        if local != state.to { state.to = local }
    }

    /// 没地方落（绳子收起了、卡片没排出来）：原地淡掉；落下后也用它淡掉
    func fadeAway(duration: TimeInterval = 0.2) {
        guard !finished else { return }
        finished = true
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; window.animator().alphaValue = 0 },
                                            completionHandler: { [self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.close()
                keepAlive = nil
            }
        })
    }
}

/// 飞的这张现在的状态（画面按它和当前时间算）
@MainActor
final class FlightState: ObservableObject {
    let image: NSImage
    let from: CGRect
    let flashes: Bool
    @Published var to: CGRect = .zero
    @Published var tilt: Double = 0
    @Published var flyStart: Date?
    @Published var flashStart: Date?

    init(image: NSImage, from: CGRect, flashes: Bool) {
        self.image = image
        self.from = from
        self.flashes = flashes
    }

    /// 飞了几成（0…1）
    func progress(at date: Date) -> Double {
        guard let flyStart else { return 0 }
        return min(1, max(0, date.timeIntervalSince(flyStart) / ClotheslineFlight.duration))
    }

    /// 还要不要一帧一帧地画（没飞、没闪的时候不画，不占资源）
    func isAnimating(at date: Date) -> Bool {
        if let flyStart, date.timeIntervalSince(flyStart) < ClotheslineFlight.duration + 0.05 { return true }
        if let flashStart, date.timeIntervalSince(flashStart) < 0.5 { return true }
        return false
    }
}

/// 飞的那张卡片：和绳上的卡片同一套玻璃框、夹子，按进度长出来
struct FlightView: View {
    @ObservedObject var state: FlightState

    var body: some View {
        TimelineView(.animation(paused: !state.isAnimating(at: Date()))) { context in
            ZStack(alignment: .topLeading) {
                card(at: state.progress(at: context.date))
                flash(at: context.date)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func card(at raw: Double) -> some View {
        let k = Self.easeInOutCubic(raw)
        let chrome = Self.smooth(k, from: 0.35, to: 1)
        let from = state.from, to = state.flyStart == nil ? state.from : state.to
        let width = Self.lerp(from.width, to.width, k)
        let height = Self.lerp(from.height, to.height, k)
        let centerX = Self.lerp(from.midX, to.midX, k)
        let top = Self.lerp(from.minY, to.minY, k) - sin(.pi * k) * 30   // 往上拱一点
        let inset = CardFrame.inset * k
        let radius = CardFrame.radius * k
        let photoShape = RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)

        ZStack(alignment: .top) {
            // 玻璃框和影子：后半程淡入
            Color.clear
                .glassFrame(cornerRadius: radius)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .opacity(chrome)
            Image(nsImage: state.image)
                .resizable()
                .interpolation(.high)
                .frame(width: max(1, width - inset * 2), height: max(1, height - inset * 2))
                .clipShape(photoShape)
                .overlay(photoShape.strokeBorder(Color.white.opacity(0.18 * chrome), lineWidth: 0.5))
                .padding(inset)
            // 夹子：和绳上一样，露出卡片上沿 14 点
            Clothespin()
                .offset(y: -14)
                .opacity(chrome)
        }
        .frame(width: width, height: height)
        .rotationEffect(.degrees(state.tilt * k))
        .position(x: centerX, y: top + height / 2)
    }

    /// 截整个屏幕时全屏闪一下白：0.85 → 0，0.45 秒
    @ViewBuilder
    private func flash(at date: Date) -> some View {
        if let start = state.flashStart {
            let t = date.timeIntervalSince(start) / 0.45
            if t < 1 {
                Color.white.opacity(0.85 * (1 - Self.easeOut(t)))
            }
        }
    }

    // 和网站 util.js 里的同名函数一样
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    static func easeInOutCubic(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
    static func smooth(_ x: Double, from a: Double, to b: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
