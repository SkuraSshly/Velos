import CoreGraphics
import Foundation

/// 截图的后期效果（纯计算，可以在后台线程调用，单元测试直接测）：
/// - 窗口阴影：整个窗口截图时切出窗口的圆角，四周加上和系统截图一样的柔和阴影（阴影外透明）
enum ImageEffects {
    /// 四周留出的空白（点）
    struct Insets: Equatable {
        var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat

        static func uniform(_ value: CGFloat) -> Insets { Insets(top: value, left: value, bottom: value, right: value) }
    }

    // MARK: - 窗口阴影

    /// 窗口阴影的样子（点）：往下偏一点、下面留得比上面多，和 macOS 窗口的阴影一致
    static let windowShadowInsets = Insets(top: 24, left: 34, bottom: 46, right: 34)
    private static let windowShadowBlur: CGFloat = 24
    private static let windowShadowOffset: CGFloat = 12
    private static let windowShadowOpacity: CGFloat = 0.38

    /// 切出窗口圆角、加上阴影
    /// - Parameters:
    ///   - scale: 每点像素数
    ///   - cornerRadius: 窗口圆角（像素）
    /// - Returns: 四周加了透明空白和阴影的图（每边多出 windowShadowInsets × scale 像素）
    static func windowWithShadow(_ image: CGImage, scale: CGFloat, cornerRadius: CGFloat) -> CGImage? {
        let insets = windowShadowInsets
        return composite(image, scale: scale, insets: insets, cornerRadius: cornerRadius, background: nil,
                         shadow: (blur: windowShadowBlur, offset: windowShadowOffset, opacity: windowShadowOpacity))
    }

    /// 从窗口单独截下的图（不带阴影，圆角外透明）量出窗口的圆角（像素）。
    /// 沿左上角的对角线往里找第一个不透明的像素：圆角半径 r 的圆弧和对角线交在 r × (1 − 1/√2) 处
    static func measuredCornerRadius(of windowImage: CGImage) -> CGFloat? {
        let size = min(windowImage.width, windowImage.height, 160)
        guard size >= 4,
              let corner = windowImage.cropping(to: CGRect(x: 0, y: 0, width: size, height: size)),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: size, height: size))
        // 位图第 0 行是图的最上面一行（CGContext 的内存从上往下排）
        for i in 0..<size {
            let alpha = data[(i * size + i) * 4 + 3]
            if alpha >= 128 {
                return i == 0 ? 0 : (CGFloat(i) / (1 - 1 / 2.0.squareRoot())).rounded()
            }
        }
        return nil   // 整个角都是透明的：不是正常的窗口
    }

    // MARK: - 合成

    /// 画一张更大的图：先铺底色（没有就透明），再在中间画切了圆角的原图，原图的形状投下阴影
    private static func composite(_ image: CGImage, scale: CGFloat, insets: Insets, cornerRadius: CGFloat,
                                  background: [CGColor]?,
                                  shadow: (blur: CGFloat, offset: CGFloat, opacity: CGFloat)?) -> CGImage? {
        let left = (insets.left * scale).rounded(), right = (insets.right * scale).rounded()
        let top = (insets.top * scale).rounded(), bottom = (insets.bottom * scale).rounded()
        let width = image.width + Int(left + right), height = image.height + Int(top + bottom)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        /// 铺底色：左上 → 右下的渐变（CGContext 原点在左下角）
        func fillBackground() {
            guard let background, !background.isEmpty else { return }
            if background.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                                 colors: background as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                context.setFillColor(background[0])
                context.fill(canvas)
            }
        }
        fillBackground()
        // CGContext 原点在左下角：图的下边距是 bottom
        let imageRect = CGRect(x: left, y: bottom, width: CGFloat(image.width), height: CGFloat(image.height))
        let shape = CGPath(roundedRect: imageRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        if let shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow.offset * scale), blur: shadow.blur * scale,
                              color: CGColor(gray: 0, alpha: shadow.opacity))
            // 用不透明的形状投阴影（图片本身可能有半透明的地方，投出来的阴影会深浅不一）
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        // 先把形状里面清空（投阴影用的黑色形状不能从图的透明处透出来），有底色时重新铺上底色，再画图
        context.clear(imageRect)
        fillBackground()
        context.interpolationQuality = .none
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }
}
