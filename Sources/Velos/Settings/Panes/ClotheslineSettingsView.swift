import SwiftUI

/// 晾衣绳：开关、怎么放下来、照片大小和保留几张、从哪里收图、怎么用
struct ClotheslineSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "晾衣绳",
                            footer: "截图和录屏挂在本机（~/Library/Application Support 里），不上传。设计来自开源项目 Tendedero 和 Picline。") {
                SwitchRow(icon: "photo.on.rectangle.angled", tint: .apricot, title: "使用晾衣绳",
                          caption: "截完图、录完屏都挂到屏幕顶上的绳子上。关掉时绳上的截图立即清空。",
                          isFirst: true, isOn: $prefs.clotheslineEnabled)
            }

            SettingsSection(title: "放下来",
                            footer: "鼠标不动时晾衣绳不占任何资源。") {
                SwitchRow(icon: "cursorarrow.motionlines", tint: .chipSky, title: "按住 \(modifier.symbol) 把鼠标移到屏幕最上面时放下来",
                          caption: "全屏 App 里也行。不按 \(modifier.symbol) 时碰到顶部不会掉下来，不挡菜单栏。鼠标离开绳子 1 秒收回去。",
                          isFirst: true, isOn: $prefs.clotheslineHover)
                SettingsRow(icon: "", title: "按住哪个键", indented: true) {
                    WarmSegmented(options: ClotheslineModifier.allCases.map { ($0.rawValue, $0.symbol) },
                                  selection: $prefs.clotheslineModifier, segmentWidth: 40)
                }
                .disabled(!prefs.clotheslineHover)
                SettingsRow(icon: "keyboard", tint: .chipLavender, title: "快捷键",
                            caption: "按 \(prefs.clotheslineHotkey.displayString) 放下 / 收起，可以在「快捷键」里改。") {
                    EmptyView()
                }
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "照片") {
                SettingsRow(icon: "rectangle.3.group", tint: .chipHoney, title: "照片大小", isFirst: true) {
                    WarmSegmented(options: ClotheslineSize.allCases.map { ($0.rawValue, $0.title) },
                                  selection: $prefs.clotheslineSize, segmentWidth: 44)
                }
                SettingsRow(icon: "square.stack.3d.down.right", tint: .chipSage, title: "保留几张",
                            caption: "多于屏幕放得下的，在绳子上双指左右滑（或滚轮）看更早的。钉在绳上的不算、也不会被挤掉。") {
                    WarmSegmented(options: ClotheslineLayout.keepChoices.map { ($0, $0 == 0 ? "放得下的" : "\($0) 张") },
                                  selection: $prefs.clotheslineKeep, segmentWidth: 66)
                }
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "收图",
                            footer: "按住访达、浏览器里的图片往屏幕顶上拖，绳子会下来接，松手就挂上（不用设置）。") {
                SwitchRow(icon: "doc.on.clipboard", tint: .chipRose, title: "接收剪贴板里的图片",
                          caption: "在别的软件、浏览器里复制的图片也挂上绳。macOS 没有「剪贴板变了」的通知，打开后每秒看两次剪贴板有没有变（只看一个计数，变了才读）。跳过密码管理器标记为私密的内容。",
                          isFirst: true, isOn: $prefs.clotheslineClipboard)
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "怎么用") {
                SettingsRow(icon: "hand.tap", tint: .chipCocoa, title: "绳上的操作", caption: usage, isFirst: true) {
                    EmptyView()
                }
            }
        }
    }

    private var modifier: ClotheslineModifier { ClotheslineModifier(rawValue: prefs.clotheslineModifier) ?? .option }

    private var usage: String {
        "鼠标停在一张上：右下角是复制，右上角是衣架（钉在绳上）和钉图，左上角 ✕ 取下；录屏右下角是 GIF 和复制、左下角是删除；按空格快速查看（按住看、松开回去；点按一直开着）；拖进其他 App 就是发过去，它会从绳上走掉；⌘ 单击加选、⇧ 单击连选后一起拖走；右键可以打开、共享、保存；拖到废纸篓也是取下。"
    }
}
