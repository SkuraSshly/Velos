import AppKit
import SwiftUI

/// 自己画的图标（系统图标里没有合适的）。都是模板图：颜色由按钮决定（平时暖棕色，选中时白色），和系统图标一致
enum VelosIcons {
    /// 长截图：上面一个开口的框（一整页），下面一把剪刀（剪下来）
    static let longCapture: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            drawLongCapture()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "长截图"
        return image
    }()

    /// 晾衣绳：一根微微下垂的绳子，上面用夹子夹着两张歪歪的照片
    static let clothesline: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            drawClothesline()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "晾衣绳"
        return image
    }()

    /// 在 18 × 18 的坐标里画（y 轴向下）。小到 15 点也要认得出来：绳子细、照片是实心的、彼此留出空隙
    static func drawClothesline(color: NSColor = .black) {
        color.set()
        // 绳子：从左到右微微下垂
        let rope = NSBezierPath()
        rope.lineWidth = 1.2
        rope.lineCapStyle = .round
        rope.move(to: CGPoint(x: 1, y: 3.4))
        rope.curve(to: CGPoint(x: 17, y: 3.4), controlPoint1: CGPoint(x: 6, y: 5.6), controlPoint2: CGPoint(x: 12, y: 5.6))
        rope.stroke()
        // 两张照片：顶边挂在绳子上，各歪一点；上面一个小夹子
        func photo(center: CGPoint, size: CGSize, degrees: CGFloat) {
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: degrees)
            let card = NSBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                                    xRadius: 1.1, yRadius: 1.1)
            card.append(NSBezierPath(roundedRect: CGRect(x: -0.75, y: -size.height / 2 - 2.2, width: 1.5, height: 2.6),
                                     xRadius: 0.5, yRadius: 0.5))
            card.transform(using: transform as AffineTransform)
            card.fill()
        }
        photo(center: CGPoint(x: 5.1, y: 9.9), size: CGSize(width: 5.6, height: 7), degrees: -7)
        photo(center: CGPoint(x: 12.9, y: 10.1), size: CGSize(width: 5.6, height: 7), degrees: 7)
    }

    /// 自己画的图标的名字：设置里图标和系统图标用同一个字符串表示，见 Glyph
    static func named(_ name: String) -> NSImage? {
        switch name {
        case Glyph.clothesline: clothesline
        case Glyph.longCapture: longCapture
        default: nil
        }
    }

    /// 在 18 × 18 的坐标里画（y 轴向下）
    static func drawLongCapture(color: NSColor = .black) {
        color.setStroke()
        let frame = NSBezierPath()
        frame.lineWidth = 1.5
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        // 开口的框：左边、上边（圆角）、右边，底边留空
        frame.move(to: CGPoint(x: 3.25, y: 9.6))
        frame.line(to: CGPoint(x: 3.25, y: 4.5))
        frame.appendArc(withCenter: CGPoint(x: 5, y: 4.5), radius: 1.75, startAngle: 180, endAngle: 270, clockwise: false)
        frame.line(to: CGPoint(x: 13, y: 2.75))
        frame.appendArc(withCenter: CGPoint(x: 13, y: 4.5), radius: 1.75, startAngle: 270, endAngle: 360, clockwise: false)
        frame.line(to: CGPoint(x: 14.75, y: 9.6))
        frame.stroke()

        // 剪刀：两条刀刃在框的下沿交叉，下面两个圆形把手
        let blades = NSBezierPath()
        blades.lineWidth = 1.5
        blades.lineCapStyle = .round
        blades.move(to: CGPoint(x: 6.6, y: 6.4))
        blades.line(to: CGPoint(x: 11.3, y: 13.2))
        blades.move(to: CGPoint(x: 11.4, y: 6.4))
        blades.line(to: CGPoint(x: 6.7, y: 13.2))
        blades.stroke()
        for center in [CGPoint(x: 5.7, y: 14.9), CGPoint(x: 12.3, y: 14.9)] {
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 1.9, y: center.y - 1.9, width: 3.8, height: 3.8))
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }
}

/// 图标：系统图标（SF Symbols）的名字，或 Velos 自己画的图标（名字以 velos. 开头）
struct Glyph: View {
    static let clothesline = "velos.clothesline"
    static let longCapture = "velos.longCapture"

    let name: String
    /// 和系统图标的字号一样大
    var size: CGFloat = 13

    init(_ name: String, size: CGFloat = 13) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let image = VelosIcons.named(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: size * 1.35, height: size * 1.35)
        } else {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        }
    }
}

/// 菜单栏图标：和 App 图标同一个前倾的「V」（Velos 在希腊语里是「箭」）——左刃细且淡、右刃粗。
/// （18pt 里放不下扫描线，加上会像一个划掉的 V，所以菜单栏只留两片刃）
/// 模板图：颜色跟着菜单栏走（浅色 / 深色自动适配）。形状和 scripts/make-icon.swift 里的是同一组坐标。
enum VelosMark {
    static let menuBar: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // App 图标里 V 的范围约是 1024 坐标的 (250…800, 230…830)，放进 18pt
            context.translateBy(x: 9, y: 9)
            context.scaleBy(x: 0.0265, y: 0.0265)
            context.translateBy(x: -530, y: -525)
            let rotate = CGAffineTransform(translationX: 512, y: 512).rotated(by: -0.10).translatedBy(x: -512, y: -512)
            let tip = CGPoint(x: 486, y: 246)
            func blade(_ points: [CGPoint]) {
                let path = CGMutablePath()
                path.addLines(between: points, transform: rotate)
                path.closeSubpath()
                context.addPath(path)
                context.fillPath()
            }
            // 菜单栏里刃加宽一些，小尺寸也看得清；左刃淡一点，和右刃区分开
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7))   // 用 sRGB（和其他界面同一种色彩空间）：灰度黑要系统另外生成一套颜色转换表，多占约 1.6 MB
            blade([CGPoint(x: 252, y: 760), CGPoint(x: 372, y: 760), CGPoint(x: tip.x + 50, y: tip.y + 14), tip])
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            blade([CGPoint(x: 660, y: 806), CGPoint(x: 812, y: 806), CGPoint(x: tip.x + 66, y: tip.y + 4), tip])
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Velos"
        return image
    }()
}


/// 设置窗口左上角的字标：「Velos」用 App 图标里 V 的配色（浅杏 → 珊瑚 → 绯红的渐变），
/// 一道带辉光的扫描线横穿字的中部，周围散着白色和珊瑚色的光点（和 App 图标的光点同一种画法）
struct VelosWordmark: View {
    var fontSize: CGFloat = 30

    private static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }
    private static let fill = LinearGradient(
        colors: [hex(0xFDB083), hex(0xF88E63), hex(0xF7784F), hex(0xE8544D), hex(0xC93A4E)],
        startPoint: UnitPoint(x: 0, y: 0), endPoint: UnitPoint(x: 1, y: 1))

    /// 固定种子的光点：位置用 0…1 的比例表示（相对整个字标），每次画出来一样
    private struct Dot { let x, y, r, alpha: Double; let white: Bool }
    private static let dots: [Dot] = {
        var state: UInt64 = 20261109
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        var dots: [Dot] = []
        for _ in 0..<9 {   // 沿扫描线
            dots.append(Dot(x: 0.02 + next() * 0.96, y: 0.55 + (next() - 0.5) * 0.5 * (0.3 + next()),
                            r: 0.5 + next() * 0.9, alpha: 0.35 + next() * 0.55, white: next() < 0.5))
        }
        for i in 0..<8 {   // 从右上角（字尾）往外散开，越远越小越淡
            let d = 0.02 + Double(i) * 0.014 + next() * 0.03
            let angle = -0.6 + (next() - 0.5) * 1.3
            let fade = max(0.15, 1 - d / 0.2)
            dots.append(Dot(x: 0.93 + cos(angle) * d, y: 0.3 + sin(angle) * d * 2.2,
                            r: (0.5 + next() * 0.9) * (0.5 + fade), alpha: fade * (0.5 + next() * 0.5), white: next() < 0.6))
        }
        return dots
    }()

    private var word: some View {
        Text("Velos")
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .fixedSize()
            // 圆体没有斜体字形，用错切往前倾（和图标里前倾的 V 一个方向）
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: fontSize * 0.08, ty: 0))
    }

    var body: some View {
        word.hidden()
            .overlay {
                ZStack {
                    // 字后面一层同色柔光
                    word.foregroundStyle(Self.fill).blur(radius: 3).opacity(0.3)
                    word.foregroundStyle(Self.fill)
                    // 扫描线：中间亮、两头淡出，再加一层虚光
                    GeometryReader { geo in
                        let y = geo.size.height * 0.55
                        let line = LinearGradient(stops: [.init(color: Self.hex(0xE2673F, 0), location: 0),
                                                          .init(color: Self.hex(0xE2673F, 0.9), location: 0.35),
                                                          .init(color: Self.hex(0xFFF4EA), location: 0.6),
                                                          .init(color: Self.hex(0xE2673F, 0.85), location: 0.8),
                                                          .init(color: Self.hex(0xE2673F, 0), location: 1)],
                                                  startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(line).frame(height: 4).blur(radius: 2.5).opacity(0.7)
                            .position(x: geo.size.width / 2, y: y)
                        Rectangle().fill(line).frame(width: geo.size.width + 16, height: 1.2)
                            .position(x: geo.size.width / 2, y: y)
                    }
                    Canvas { context, size in
                        for dot in Self.dots {
                            let center = CGPoint(x: dot.x * size.width, y: dot.y * size.height)
                            let color = dot.white ? Self.hex(0xFFFFFF, dot.alpha) : Self.hex(0xF58A5E, dot.alpha)
                            if dot.r > 1.2 {   // 大的几颗带一点虚光
                                var glow = context
                                glow.addFilter(.blur(radius: 1.5))
                                glow.fill(Path(ellipseIn: CGRect(x: center.x - dot.r * 2, y: center.y - dot.r * 2,
                                                                 width: dot.r * 4, height: dot.r * 4)), with: .color(color.opacity(0.5)))
                            }
                            context.fill(Path(ellipseIn: CGRect(x: center.x - dot.r, y: center.y - dot.r, width: dot.r * 2, height: dot.r * 2)),
                                         with: .color(color))
                        }
                    }
                    .padding(-12)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Velos")
    }
}
