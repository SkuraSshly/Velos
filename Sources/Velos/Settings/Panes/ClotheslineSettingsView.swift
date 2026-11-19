import SwiftUI

/// 晾衣绳：开关、怎么放下来、照片
struct ClotheslineSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "晾衣绳") {
                SwitchRow(title: "使用晾衣绳", isOn: $prefs.clotheslineEnabled)
                SwitchRow(title: "挂上剪贴板里的图片", isOn: $prefs.clotheslineClipboard)
                    .disabled(!prefs.clotheslineEnabled)
            }

            SettingsSection(title: "放下来") {
                SwitchRow(title: "按住 \(modifier.symbol) 把鼠标推到屏幕顶", isOn: $prefs.clotheslineHover)
                SettingsRow(title: "按住", indented: true) {
                    GlassSegmented(options: ClotheslineModifier.allCases.map { ($0.rawValue, $0.symbol) },
                                  selection: $prefs.clotheslineModifier, segmentWidth: 40)
                }
                .disabled(!prefs.clotheslineHover)
            }
            .disabled(!prefs.clotheslineEnabled)

            SettingsSection(title: "照片") {
                SettingsRow(title: "大小") {
                    GlassSegmented(options: ClotheslineSize.allCases.map { ($0.rawValue, $0.title) },
                                  selection: $prefs.clotheslineSize, segmentWidth: 44)
                }
                SettingsRow(title: "保留") {
                    GlassSegmented(options: ClotheslineLayout.keepChoices.map { ($0, $0 == 0 ? "一屏" : "\($0) 张") },
                                  selection: $prefs.clotheslineKeep, segmentWidth: 56)
                }
            }
            .disabled(!prefs.clotheslineEnabled)
        }
    }

    private var modifier: ClotheslineModifier { ClotheslineModifier(rawValue: prefs.clotheslineModifier) ?? .option }
}
