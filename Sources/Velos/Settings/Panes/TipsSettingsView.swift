import SwiftUI

/// 小技巧：各功能里不用设置、但知道了更顺手的操作。
/// 其他栏目只放能改的设置；「怎么用」都集中在这里，按功能分组。快捷键、按住的键跟着设置显示当前的值
struct TipsSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "截图") {
                tip("arrow.left.arrow.right", .chipLavender, "区域 ↔ 全屏",
                    "选区界面里再按一次打开它的快捷键（截图 \(prefs.screenshotHotkey.displayString)、录屏 \(prefs.recordingHotkey.displayString)、截屏翻译 \(prefs.translateHotkey.displayString)），按住修饰键连按、或松开后再按都行。",
                    isFirst: true)
                tip("macwindow", .chipSky, "截整个窗口",
                    "鼠标停在窗口上会自动认出整个窗口，单击就截这个窗口；拖一下就是自己框选。")
                tip("square.and.arrow.down", .chipSage, "完成并保存",
                    "截图界面按 ⌘S：完成并存成文件，不管有没有打开「自动保存到文件」。")
                tip(Glyph.longCapture, .apricot, "长截图",
                    "框选区域后点工具栏上的长截图按钮，在选区里滚动页面即可（Esc 取消）。滚得太快跟丢时会自动接回，最长 20000 像素。")
            }

            SettingsSection(title: "录屏") {
                tip("timer", .coral, "倒计时", "倒计时期间按 Esc 取消，按 Enter 立即开始。", isFirst: true)
                tip("speaker.wave.2.fill", .chipSage, "临时改声音",
                    "开始前可以在选区旁的选项条里开关系统声音、麦克风，会记住上次的选择。")
                tip("film.stack", .chipLavender, "转成 GIF",
                    "刚录完的录屏，在晾衣绳的卡片上点「GIF」；以前的录屏在 设置 › 录屏 › GIF 里选。")
            }

            SettingsSection(title: "截屏翻译") {
                tip("rectangle.dashed", .chipSky, "识别整屏", "切到全屏模式后按 Enter，识别整个屏幕。", isFirst: true)
                tip("command", .chipCocoa, "结果窗口的快捷键",
                    "⌘C 复制译文、⇧⌘C 复制原文、⌘R 重新翻译、⌘P 钉住 / 取消钉住、Esc 关闭。")
            }

            SettingsSection(title: "晾衣绳") {
                tip(Glyph.clothesline, .apricot, "叫出来",
                    "按住 \(modifier.symbol) 把鼠标移到屏幕最上面，或按 \(prefs.clotheslineHotkey.displayString)。鼠标离开绳子 1 秒就收回去。",
                    isFirst: true)
                tip("hand.tap", .chipCocoa, "卡片上的按钮",
                    "左上 ✕ 取下；右上衣架钉在绳上（不会被挤掉）；右下复制。截图左下是存文件，存好后换成删除、复制前面多一个打开文件位置；录屏右下还有 GIF。")
                tip("space", .chipLavender, "快速查看", "鼠标停在一张上按空格：按住看、松开回去；点按一下一直开着，← → 翻看其他几张。")
                tip("hand.draw", .chipSky, "拖走、多选",
                    "拖进任何 App 或访达就是放过去，它会从绳上走掉。⌘ 单击加选、⇧ 单击连选一段，一起拖走。")
                tip("arrow.uturn.backward", .chipRose, "取下和放回",
                    "鼠标在绳上时按 Delete 取下，⌘Z 放回来（最近 10 步）。在访达里删掉存好的文件，绳上那张也会跟着拿掉。")
                tip("tray.and.arrow.down", .chipHoney, "挂别的图",
                    "按住访达、浏览器里的图片往屏幕顶上拖，绳子会下来接；在访达里右键「打开方式 → Velos」，或拖到程序坞的 Velos 图标上也行。")
            }
        }
    }

    private var modifier: ClotheslineModifier { ClotheslineModifier(rawValue: prefs.clotheslineModifier) ?? .option }

    private func tip(_ icon: String, _ tint: Color, _ title: String, _ text: String, isFirst: Bool = false) -> some View {
        SettingsRow(icon: icon, tint: tint, title: title, caption: text, isFirst: isFirst) { EmptyView() }
    }
}
