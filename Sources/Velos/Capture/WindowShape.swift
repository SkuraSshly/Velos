import AppKit
import ScreenCaptureKit

/// 窗口的形状：带阴影截图时，要知道窗口的圆角有多大（不同系统版本、不同种类的窗口不一样）。
/// 单独截一次这个窗口（不带阴影，圆角外透明），从左上角量出圆角。只在完成截图时做一次，不保留任何东西
@MainActor
enum WindowShape {
    /// 截不到窗口时（例如窗口刚好关了）按这个圆角（点）
    static let fallbackRadius: CGFloat = 12

    /// 窗口圆角（像素，按 scale 换算）
    static func cornerRadius(of window: DetectedWindow, scale: CGFloat) async -> CGFloat {
        if window.id != 0, let measured = await measure(window.id) {
            return measured.radius / measured.scale * scale
        }
        return fallbackRadius * scale
    }

    private static func measure(_ id: CGWindowID) async -> (radius: CGFloat, scale: CGFloat)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
            config.captureResolution = .best
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let radius = ImageEffects.measuredCornerRadius(of: image) else { return nil }
            Log.capture.notice("窗口圆角：\(radius / scale, format: .fixed(precision: 1)) 点")
            return (radius, scale)
        } catch {
            Log.capture.error("读取窗口圆角失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
