import SwiftUI

/// 截图：格式、画面、完成后的行为（怎么用见「小技巧」）
struct ScreenshotSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文件",
                            footer: "格式只影响保存的文件，复制到剪贴板的始终是无损 PNG。文件名示例：\(SaveLocation.fileName(prefix: "截图", fileExtension: prefs.imageFormat.fileExtension))") {
                FolderRow(kind: .screenshot, icon: "folder.fill", tint: .chipHoney, title: "保存到",
                          path: $prefs.screenshotDirectoryPath, isFirst: true)
                SettingsRow(icon: "doc.richtext", tint: .chipSky, title: "文件格式") {
                    WarmSegmented(options: [(ImageFormat.png, "PNG"), (.heic, "HEIC"), (.jpeg, "JPEG")],
                                  selection: $prefs.imageFormat)
                }
                if prefs.imageFormat != .png {
                    SettingsRow(icon: "dial.medium", tint: .chipHoney, title: "压缩质量") {
                        HStack(spacing: 8) {
                            Slider(value: $prefs.jpegQuality, in: 0.6...1.0, step: 0.05)
                                .controlSize(.small)
                                .frame(width: 150)
                            Text("\(Int((prefs.jpegQuality * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.warmInk)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsSection(title: "画面",
                            footer: "默认始终以 Retina 原生像素输出，不缩放；文件写入色彩配置文件（Display P3 / sRGB）。1x 对复制和保存都生效，钉图始终是原生清晰度。") {
                SwitchRow(icon: "cursorarrow", tint: .chipCocoa, title: "包含鼠标指针", isFirst: true,
                          isOn: $prefs.screenshotIncludesCursor)
                SwitchRow(icon: "arrow.down.right.and.arrow.up.left", tint: .chipLavender, title: "按 1x 分辨率输出",
                          caption: "体积更小", isOn: $prefs.screenshotSaveAs1x)
                SwitchRow(icon: "macwindow", tint: .chipSky, title: "整个窗口截图时保留圆角",
                          caption: "单击（或悬停）选中一个窗口截图时，只截窗口本身，四个圆角外透明（和系统按住 ⌥ 截窗口一样）。框选的区域照样是直角。",
                          isOn: $prefs.windowCorners)
                SwitchRow(icon: "", title: "再加上窗口阴影",
                          caption: "四周多出一圈透明的空白和柔和的阴影。", indented: true, isOn: $prefs.windowShadow)
            }

            SettingsSection(title: "完成后", footer: footer) {
                SwitchRow(icon: "doc.on.clipboard", tint: .apricot, title: "复制到剪贴板", isFirst: true,
                          isOn: $prefs.screenshotCopyToClipboard)
                SwitchRow(icon: "square.and.arrow.down", tint: .chipSage, title: "自动保存到文件",
                          isOn: $prefs.screenshotSaveToFile)
                SwitchRow(icon: "rectangle.inset.bottomright.filled", tint: .chipSky,
                          title: prefs.clotheslineEnabled ? "截图后挂到晾衣绳上给你看" : "在屏幕角落显示缩略图",
                          caption: prefs.clotheslineEnabled ? "绳子放下来 2.5 秒。" : nil,
                          isOn: $prefs.screenshotShowThumbnail)
                SwitchRow(icon: "", title: "粘贴后自动收起缩略图",
                          caption: "用了剪贴板历史工具（如 Maccy、Paste）时，它会立即读取剪贴板，缩略图会马上收起，可关闭此项。",
                          indented: true, isOn: $prefs.hideThumbnailAfterPaste)
                    .disabled(!prefs.screenshotShowThumbnail || !prefs.screenshotCopyToClipboard)
            }
        }
    }

    private var footer: String? {
        if !prefs.screenshotCopyToClipboard && !prefs.screenshotSaveToFile && !prefs.screenshotShowThumbnail {
            return "⚠️ 复制、保存、缩略图都已关闭，截图完成后不会留下结果。"
        }
        return nil
    }
}
