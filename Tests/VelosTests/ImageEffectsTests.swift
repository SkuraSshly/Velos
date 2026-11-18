import AppKit
import Testing
@testable import Velos

/// 窗口阴影、最近截图的文件名、整个窗口的判断
@Suite struct ImageEffectsTests {
    /// 纯色不透明图（sRGB）
    func solid(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 读一个像素的 RGBA（x、y 从图的左上角算）
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[1], data[2], data[3])
    }

    @Test func 窗口阴影四周加空白_圆角外透明_中间是原图() throws {
        let image = solid(width: 400, height: 300)
        let shaped = try #require(ImageEffects.windowWithShadow(image, scale: 2, cornerRadius: 24))
        let insets = ImageEffects.windowShadowInsets
        #expect(shaped.width == 400 + Int((insets.left + insets.right) * 2))
        #expect(shaped.height == 300 + Int((insets.top + insets.bottom) * 2))
        let left = Int(insets.left * 2), top = Int(insets.top * 2)
        // 最外面的角完全透明
        #expect(pixel(shaped, 0, 0).a == 0)
        // 窗口的左上角在圆角外：透出的是很淡的阴影，不是原图
        #expect(pixel(shaped, left, top).a < 200)
        // 窗口中间就是原图
        let center = pixel(shaped, left + 200, top + 150)
        #expect(center.a == 255 && abs(Int(center.r) - 128) <= 2)
        // 阴影往下偏：窗口下面比上面深
        #expect(pixel(shaped, left + 200, top + 300 + 20).a > pixel(shaped, left + 200, top - 20).a)
    }

    @Test func 量出窗口圆角() throws {
        // 画一个 20 像素圆角的「窗口」（圆角外透明）
        let context = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 200, height: 120), cornerWidth: 20, cornerHeight: 20, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        let radius = try #require(ImageEffects.measuredCornerRadius(of: context.makeImage()!))
        #expect(abs(radius - 20) <= 4)
        // 直角窗口：0
        #expect(ImageEffects.measuredCornerRadius(of: solid(width: 50, height: 50)) == 0)
    }

    @Test func 最近截图的文件名读得回时间和缩放倍数() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.123)
        let name = ScreenshotHistory.fileName(date: date, scale: 2)
        #expect(name.hasSuffix("@2x.png"))
        let entry = try #require(ScreenshotHistory.parse(URL(fileURLWithPath: "/tmp/" + name)))
        #expect(abs(entry.date.timeIntervalSince(date)) < 0.01 && entry.scale == 2)
        // 缩略图、别的文件不算
        #expect(ScreenshotHistory.parse(ScreenshotHistory.thumbnailURL(for: URL(fileURLWithPath: "/tmp/" + name))) == nil)
        #expect(ScreenshotHistory.parse(URL(fileURLWithPath: "/tmp/截图.png")) == nil)
    }
}

/// 同一张图只挂一次（像素指纹）、检查更新的版本比较
@Suite struct ClotheslineMiscTests {
    func solid(_ gray: CGFloat, width: Int = 40, height: Int = 30) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func 像素一样指纹就一样() {
        #expect(ScreenshotHistory.pixelHash(solid(0.5)) == ScreenshotHistory.pixelHash(solid(0.5)))
        #expect(ScreenshotHistory.pixelHash(solid(0.5)) != ScreenshotHistory.pixelHash(solid(0.6)))
        // 尺寸不同（裁剪过）算不同的图
        #expect(ScreenshotHistory.pixelHash(solid(0.5)) != ScreenshotHistory.pixelHash(solid(0.5, width: 41)))
    }

    @Test func 版本号逐段按数字比较() {
        #expect(UpdateChecker.isNewer("2.10", than: "2.9"))
        #expect(UpdateChecker.isNewer("2.4.3", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("2.4", than: "2.4.0"))
        #expect(!UpdateChecker.isNewer("2.4.1", than: "2.4.2"))
    }
}

/// 整个窗口截图（带阴影）的判断：悬停或单击选中、没动过选区才算
@MainActor
@Suite struct WholeWindowTests {
    /// 选区按真实的屏幕判断点在哪块屏幕上：用主屏的编号，坐标都放在主屏左下角 1440×900 的范围里
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let displayID = NSScreen.screens.first?.displayID ?? 1

    func makeSelector(_ windows: [DetectedWindow]) -> RegionSelector {
        let selector = RegionSelector()
        selector.screens = [displayID: .init(frame: screen, scale: 2)]
        selector.windows = windows
        return selector
    }

    @Test func 悬停和单击选中整个窗口() {
        let window = DetectedWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 400), id: 7, isAppWindow: true)
        let selector = makeSelector([window])
        selector.mouseMoved(to: CGPoint(x: 300, y: 300))
        #expect(selector.targetWindow == window)
        selector.mouseDown(at: CGPoint(x: 300, y: 300))
        selector.mouseUp(at: CGPoint(x: 300, y: 300))
        #expect(selector.selection == window.frame && selector.targetWindow == window)
        // 微移之后就不是整个窗口了
        selector.nudge(dxPixels: 2, dyPixels: 0)
        #expect(selector.targetWindow == nil)
    }

    @Test func 露出屏幕外的窗口和菜单栏不算() {
        let offscreen = DetectedWindow(frame: CGRect(x: 1200, y: 100, width: 600, height: 400), id: 8, isAppWindow: true)
        let selector = makeSelector([offscreen])
        selector.mouseMoved(to: CGPoint(x: 1300, y: 300))
        #expect(selector.hoveredWindow != nil && selector.targetWindow == nil)

        let menuBar = DetectedWindow(frame: CGRect(x: 0, y: 870, width: 1440, height: 30), id: 9, isAppWindow: false)
        let other = makeSelector([menuBar])
        other.mouseMoved(to: CGPoint(x: 300, y: 880))
        #expect(other.hoveredWindow != nil && other.targetWindow == nil)
    }



}
