// 截图飞到绳上的想法来自 Tendedero（https://github.com/alejandrobujan/tendedero）的 CaptureFlight，
// Copyright (c) 2026 Alejandro Buján，MIT 许可证（全文见仓库根目录 THIRD_PARTY_NOTICES.md）。
// 这里按 Velos 的需要重写：「咔嚓」的闪白 + 拎起，再沿弧线飞过去，全部用 Core Animation（显卡画，顺滑）。

import AppKit
import QuartzCore

/// 截图（录屏）飞到晾衣绳上的那一下。
///
/// 1. 咔嚓：截下来的那块先闪一下白（像相机快门），图同时被「拎起来」：稍微缩小、影子变大，带一点弹性
/// 2. 等绳子放下来、新卡片排好位置（图在空中轻轻停着，不会僵住不动）
/// 3. 沿一条往上拱的弧线飞到卡片的位置，边飞边缩到卡片的大小、圆角，落下时真卡片出现、这张淡掉
///
/// 用一块和屏幕一样大的透明窗口当画布，图是窗口里的一个图层：图层动画由显卡做，比一帧帧改窗口大小顺滑得多。
/// 窗口不接收鼠标，飞完就关掉。
@MainActor
final class ClotheslineFlight {
    private let window: NSPanel
    private let screen: NSScreen
    private let imageLayer = CALayer()
    private let flashLayer = CALayer()

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
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let canvas = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.wantsLayer = true
        window.contentView = canvas

        let local = Self.local(start, in: screen)
        imageLayer.frame = local
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = false
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0
        imageLayer.shadowRadius = 4
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        // 图本身要切圆角（阴影在外面）：放一个子图层画图
        let picture = CALayer()
        picture.contents = image
        picture.contentsGravity = .resize
        picture.frame = imageLayer.bounds
        picture.cornerRadius = 6
        picture.masksToBounds = true
        picture.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.addSublayer(picture)
        flashLayer.frame = imageLayer.bounds
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.cornerRadius = 6
        flashLayer.opacity = 0
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.addSublayer(flashLayer)
        canvas.layer?.addSublayer(imageLayer)
    }

    private static func local(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: rect.minY - screen.frame.minY, width: rect.width, height: rect.height)
    }

    // MARK: - 1. 咔嚓

    /// 最长在屏幕上停多久：不管发生什么（没写进去、绳子没放下来、动画没回调），到点一定收掉，绝不会一直停在屏幕上
    private static let maxLifetime: TimeInterval = 6
    private var finished = false
    /// 飞完、收掉窗口之前自己拉着自己：不然没人拿着它时会被提前释放，窗口就再也没人关，图一直停在屏幕上（还点不到）
    private var keepAlive: ClotheslineFlight?

    /// 「拎起」那一下的弹簧（有一点回弹）
    private static let liftSpring = Spring(stiffness: 220, damping: 14, longest: 0.85)
    /// 飞过去的弹簧：和拎起是同一种弹簧，只是阻尼刚好不回弹（不会冲过卡片再退回来）
    /// 越软飞得越慢：49 的弹簧起步从容；但弹簧最后一段会拖很久慢慢挪，
    /// 所以只用前 0.7 秒、并把它拉伸成正好在 0.7 秒到位：前面不变，落下时还带着一点速度，不会磨蹭
    private static let flySpring = Spring(stiffness: 49, damping: 14, longest: 0.7)
    /// 什么时候开始拎起的：起飞时算出这一刻缩到了多少，从这里接着动，不会跳一下
    private var snappedAt = CACurrentMediaTime()

    /// 闪白 + 拎起（立刻开始，0.3 秒）
    func snap() {
        keepAlive = self
        snappedAt = CACurrentMediaTime()
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLifetime) { [self] in
            guard !finished else { return }
            Log.capture.notice("晾衣绳：飞的截图超时，收掉")
            self.fadeAway()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.85, 0]
        flash.keyTimes = [0, 0.12, 1]
        flash.duration = 0.32
        flash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        flashLayer.add(flash, forKey: "flash")

        // 拎起：缩到 92%，带一点回弹；影子同时变大变深
        let lift = Self.liftSpring.animation("transform.scale", from: 1, to: 0.92)
        imageLayer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        imageLayer.add(lift, forKey: "lift")

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = 0.35
        shadow.duration = 0.25
        imageLayer.shadowOpacity = 0.35
        imageLayer.shadowRadius = 18
        imageLayer.shadowOffset = CGSize(width: 0, height: -8)
        imageLayer.add(shadow, forKey: "shadow")
        CATransaction.commit()
    }

    // MARK: - 2、3. 飞过去

    /// 沿弧线飞到 target（全局坐标，卡片里照片的位置），落下后调用 landed
    ///
    /// 和拎起用同一种弹簧：起步时轻轻加速、快到时慢慢停稳。位置、大小、角度、圆角、影子全按同一条弹簧曲线走，
    /// 弧线也是按这条曲线一点点算出来的，所以飞的过程是一整个动作，不会某一部分先到、某一部分后到。
    /// - Parameter tilt: 卡片挂着歪的角度（度，顺时针为正）：飞到时也歪成一样，接上真卡片不会跳一下
    func fly(to target: CGRect, cornerRadius: CGFloat, tilt: Double = 0, landed: @escaping () -> Void) {
        // 拎起的弹簧可能还在轻轻晃：算出这一刻缩到多少，从这里接着飞（不读屏幕上正在显示的那一帧，那个值有时是空的）
        let elapsed = CACurrentMediaTime() - snappedAt
        let scale = 1 + (0.92 - 1) * Self.liftSpring.progress(at: elapsed)
        imageLayer.removeAnimation(forKey: "lift")
        let startPosition = imageLayer.position
        let startBounds = imageLayer.bounds
        let end = Self.local(target, in: screen)
        let endPosition = CGPoint(x: end.midX, y: end.midY)

        // 往上拱的弧线：控制点在两点连线中间、再往上一些（绳子在屏幕顶上，弧线自然地「抛」上去）
        let control = CGPoint(x: (startPosition.x + endPosition.x) / 2,
                              y: max(startPosition.y, endPosition.y) + min(160, abs(endPosition.x - startPosition.x) * 0.25 + 60))
        let spring = Self.flySpring
        let duration = spring.longest
        // 每 1/120 秒取一个点，每个点走到几成由弹簧决定（拉伸到最后正好 100%）。
        // 位置、大小、角度、圆角、影子全用这同一组点，整个动作一起起步、一起落下
        let steps = Int(duration * 120)
        let progress: [Double] = (0...steps).map { spring.fitted(at: duration * Double($0) / Double(steps)) }
        func frames(_ keyPath: String, _ value: (Double) -> Any) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = progress.map(value)
            animation.duration = duration
            animation.calculationMode = .linear
            return animation
        }
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

        // 拎起时缩小的部分平滑回到 100%（大小由 bounds 决定），同时转到卡片的角度
        // （屏幕坐标 y 朝上，逆时针为正：SwiftUI 里顺时针的 tilt 这里取负）
        let angle = -CGFloat(tilt) * .pi / 180
        let finalTransform = CATransform3DMakeRotation(angle, 0, 0, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated {
                landed()
                // 真卡片在下面淡入，这张在上面同时淡出（0.16 秒，和 Picline 一样）
                fadeAway(duration: 0.16)
            }
        }
        let move = frames("position") { t in
            let u = 1 - t
            return NSValue(point: CGPoint(x: u * u * startPosition.x + 2 * u * t * control.x + t * t * endPosition.x,
                                          y: u * u * startPosition.y + 2 * u * t * control.y + t * t * endPosition.y))
        }
        let resize = frames("bounds") { t in
            NSValue(rect: CGRect(x: 0, y: 0, width: mix(startBounds.width, end.width, t), height: mix(startBounds.height, end.height, t)))
        }
        let unscale = frames("transform") { t in
            let k = mix(scale, 1, t)
            return NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeRotation(mix(0, angle, t), 0, 0, 1), k, k, 1))
        }
        let shadow = frames("shadowOpacity") { t in Float(mix(0.35, 0.18, t)) }

        imageLayer.position = endPosition
        imageLayer.bounds = CGRect(origin: .zero, size: end.size)
        imageLayer.transform = finalTransform
        imageLayer.shadowOpacity = 0.18
        imageLayer.add(move, forKey: "move")
        imageLayer.add(resize, forKey: "resize")
        imageLayer.add(unscale, forKey: "unscale")
        imageLayer.add(shadow, forKey: "shadowFly")
        for sub in imageLayer.sublayers ?? [] {
            let from = sub.cornerRadius
            let radius = frames("cornerRadius") { t in mix(from, cornerRadius, t) }
            sub.cornerRadius = cornerRadius
            sub.add(radius, forKey: "radius")
        }
        CATransaction.commit()
    }

    /// 没地方落（绳子收起了、卡片没排出来）：原地淡掉
    func fadeAway(duration: TimeInterval = 0.2) {
        guard !finished else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; window.animator().alphaValue = 0 },
                                            completionHandler: { [self] in MainActor.assumeIsolated { finish() } })
    }

    /// 真卡片已经出现：下一帧再收掉这张（中间不会空一下）
    private func finish() {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { [self] in
            window.orderOut(nil)
            window.close()
            keepAlive = nil
        }
    }
}

/// 弹簧（质量 1）：系统的弹簧动画，加上「某一时刻走到了几成」的算法，好让弧线、接着拎起往下飞都和它对得上
private struct Spring {
    let stiffness: Double
    let damping: Double
    /// 最多动多久：系统算的停稳时间偏保守（最后一大段都是看不出来的微动），截掉那段，到那时已经走完 99.8% 以上
    let longest: CFTimeInterval

    func animation(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = damping
        spring.fromValue = from
        spring.toValue = to
        spring.duration = min(spring.settlingDuration, longest)
        return spring
    }

    /// 前 longest 秒的弹簧拉伸成正好在 longest 秒走到 100%（不要最后那段拖很久的慢慢挪）
    func fitted(at t: Double) -> Double {
        min(1, progress(at: t) / progress(at: longest))
    }

    /// 从静止出发，t 秒时走到了几成（0 → 1，回弹时会稍微超过 1）
    func progress(at t: Double) -> Double {
        let omega = stiffness.squareRoot()
        let zeta = damping / (2 * omega)
        if zeta < 1 {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(omegaD * t) + zeta * omega / omegaD * sin(omegaD * t))
        }
        return 1 - (1 + omega * t) * exp(-omega * t)   // 刚好不回弹（临界阻尼）
    }
}
