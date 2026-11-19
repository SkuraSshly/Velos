import SwiftUI

/// 录屏：文件、画面、声音、录制、GIF
struct RecordingSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文件") {
                FolderRow(kind: .recording, path: $prefs.recordingDirectoryPath)
            }

            SettingsSection(title: "画面") {
                SettingsRow(title: "分辨率") {
                    GlassSegmented(options: [(RecordingResolution.native, "原生"), (.p1080, "1080p")],
                                  selection: $prefs.recordingResolution)
                }
                SettingsRow(title: "帧率") {
                    GlassSegmented(options: [(RecordingFrameRate.fps60, "60 fps"), (.fps30, "30 fps")],
                                  selection: $prefs.recordingFrameRate)
                }
                SettingsRow(title: "编码") {
                    GlassSegmented(options: [(VideoCodec.hevc, "HEVC"), (.h264, "H.264")], selection: $prefs.videoCodec)
                }
                SettingsRow(title: "画质") {
                    GlassSegmented(options: VideoQuality.allCases.map { ($0, $0.title) }, selection: $prefs.videoQuality)
                }
            }

            SettingsSection(title: "声音") {
                SwitchRow(title: "录制系统声音", isOn: $prefs.recordSystemAudio)
                SwitchRow(title: "录制麦克风", isOn: $prefs.recordMicrophone)
            }

            SettingsSection(title: "录制") {
                SwitchRow(title: "显示鼠标指针", isOn: $prefs.recordingShowsCursor)
                SwitchRow(title: "高亮鼠标点击", isOn: $prefs.highlightClicks)
                SwitchRow(title: "3 秒倒计时", isOn: $prefs.recordingCountdown)
                SwitchRow(title: prefs.clotheslineEnabled ? "录完放下晾衣绳" : "录完显示缩略图",
                          isOn: $prefs.recordingShowThumbnail)
            }

            SettingsSection(title: "GIF") {
                SettingsRow(title: "帧率") {
                    GlassSegmented(options: GIFFrameRate.allCases.map { ($0, $0.title) }, selection: $prefs.gifFrameRate)
                }
                SettingsRow(title: "最大宽度") {
                    GlassSegmented(options: GIFMaxWidth.allCases.map { ($0, $0 == .original ? "原宽" : "\($0.rawValue)") },
                                  selection: $prefs.gifMaxWidth)
                }
                SettingsRow(title: "把录屏转成 GIF") {
                    Button("选择…") { GIFConversion.chooseAndConvert() }
                        .buttonStyle(CapsuleButtonStyle())
                }
            }
        }
        .onChange(of: prefs.recordMicrophone) { _, enabled in
            // 打开麦克风时顺便请求权限（未决定时弹系统对话框；被拒绝过则跳到系统设置）
            if enabled && !PermissionManager.shared.microphoneGranted {
                PermissionManager.shared.requestMicrophone()
            }
        }
    }
}
