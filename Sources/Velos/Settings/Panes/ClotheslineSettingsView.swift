import SwiftUI

/// 晾衣绳：开关、怎么放下来、照片大小和保留几张、收剪贴板里的图（怎么用见「小技巧」，快捷键见「快捷键」）
struct ClotheslineSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "晾衣绳",
                            footer: "截图和录屏挂在本机（~/Library/Application Support 里），不上传。设计来自开源项目 Tendedero 和 Picline。") {
                SwitchRow(icon: Glyph.clothesline, tint: .apricot, title: "使用晾衣绳",
                          caption: "截完图、录完屏都挂到屏幕顶上的绳子上。关掉时绳上的截图立即清空。",
                          isFirst: true, isOn: $prefs.clotheslineEnabled)
            }

            SettingsSection(title: "放下来",
                            footer: "鼠标不动时晾衣绳不占任何资源。") {
                SwitchRow(icon: "cursorarrow.motionlines", tint: .chipSky, title: "按住 \(modifier.symbol) 把鼠标移到屏幕最上面时放下来",
                          caption: "全屏 App 里也行；不按 \(modifier.symbol) 时碰到顶部不会掉下来，不挡菜单栏。",
                          isFirst: true, isOn: $prefs.clotheslineHover)
                SettingsRow(icon: "", title: "按住哪个键", indented: true) {
                    WarmSegmented(options: ClotheslineModifier.allCases.map { ($0.rawValue, $0.symbol) },
                                  selection: $prefs.clotheslineModifier, segmentWidth: 40)
                }
                .disabled(!prefs.clotheslineHover)
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "照片") {
                SettingsRow(icon: "rectangle.3.group", tint: .chipHoney, title: "照片大小", isFirst: true) {
                    WarmSegmented(options: ClotheslineSize.allCases.map { ($0.rawValue, $0.title) },
                                  selection: $prefs.clotheslineSize, segmentWidth: 44)
                }
                SettingsRow(icon: "square.stack.3d.down.right", tint: .chipSage, title: "保留几张",
                            caption: "多出来的在绳上双指左右滑（或滚轮）看。钉在绳上的不算在内。") {
                    WarmSegmented(options: ClotheslineLayout.keepChoices.map { ($0, $0 == 0 ? "放得下的" : "\($0) 张") },
                                  selection: $prefs.clotheslineKeep, segmentWidth: 66)
                }
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "收图",
                            footer: "macOS 没有「剪贴板变了」的通知，打开后每秒看两次剪贴板有没有变（只看一个计数，变了才读）。") {
                SwitchRow(icon: "doc.on.clipboard", tint: .chipRose, title: "接收剪贴板里的图片",
                          caption: "在别的软件、浏览器里复制的图片也挂上绳。跳过密码管理器标记为私密的内容。",
                          isFirst: true, isOn: $prefs.clotheslineClipboard)
            }
            .disabled(!prefs.clotheslineEnabled)
        }
    }

    private var modifier: ClotheslineModifier { ClotheslineModifier(rawValue: prefs.clotheslineModifier) ?? .option }
}
