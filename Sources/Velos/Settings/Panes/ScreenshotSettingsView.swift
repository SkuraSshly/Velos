import SwiftUI

/// 截图：文件、画面、完成后
struct ScreenshotSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文件") {
                FolderRow(kind: .screenshot, path: $prefs.screenshotDirectoryPath)
                SettingsRow(title: "格式") {
                    GlassSegmented(options: [(ImageFormat.png, "PNG"), (.heic, "HEIC"), (.jpeg, "JPEG")],
                                  selection: $prefs.imageFormat)
                }
                if prefs.imageFormat != .png {
                    SettingsRow(title: "质量", indented: true) {
                        HStack(spacing: 8) {
                            Slider(value: $prefs.jpegQuality, in: 0.6...1.0, step: 0.05)
                                .controlSize(.small)
                                .frame(width: 150)
                            Text("\(Int((prefs.jpegQuality * 100).rounded()))%")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(Color.inkSecondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsSection(title: "画面") {
                SwitchRow(title: "包含鼠标指针", isOn: $prefs.screenshotIncludesCursor)
                SwitchRow(title: "缩小到 1x", isOn: $prefs.screenshotSaveAs1x)
                SwitchRow(title: "窗口保留圆角", isOn: $prefs.windowCorners)
                SwitchRow(title: "窗口加阴影", isOn: $prefs.windowShadow)
            }

            SettingsSection(title: "完成后") {
                SwitchRow(title: "复制到剪贴板", isOn: $prefs.screenshotCopyToClipboard)
                SwitchRow(title: "保存到文件", isOn: $prefs.screenshotSaveToFile)
                SwitchRow(title: prefs.clotheslineEnabled ? "放下晾衣绳" : "显示缩略图",
                          caption: leavesNothing ? "⚠️ 截图后什么都不会留下" : nil,
                          isOn: $prefs.screenshotShowThumbnail)
                // 开着晾衣绳时没有角落的缩略图
                if !prefs.clotheslineEnabled {
                    SwitchRow(title: "粘贴后收起缩略图", indented: true, isOn: $prefs.hideThumbnailAfterPaste)
                        .disabled(!prefs.screenshotShowThumbnail || !prefs.screenshotCopyToClipboard)
                }
            }
        }
    }

    /// 开着晾衣绳时截图总会挂到绳上；没开时三项都关就什么都不留
    private var leavesNothing: Bool {
        !prefs.clotheslineEnabled && !prefs.screenshotCopyToClipboard && !prefs.screenshotSaveToFile && !prefs.screenshotShowThumbnail
    }
}
