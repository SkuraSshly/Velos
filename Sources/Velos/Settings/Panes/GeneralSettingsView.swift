import AVFoundation
import SwiftUI

/// 通用：启动、声音、删除文件、更新、权限（保存位置在「截图」「录屏」里）
struct GeneralSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "启动") {
                SettingsRow(title: "登录时打开", caption: launchAtLogin.lastError) {
                    HStack(spacing: 8) {
                        if launchAtLogin.requiresApproval {
                            Button("去允许") { launchAtLogin.openSystemSettings() }
                                .buttonStyle(CapsuleButtonStyle())
                        }
                        Toggle("", isOn: launchAtLoginBinding).toggleStyle(GlassSwitchStyle()).labelsHidden()
                    }
                }
                SwitchRow(title: "菜单栏图标", isOn: $prefs.showMenuBarIcon)
                SwitchRow(title: "程序坞图标", isOn: $prefs.showDockIcon)
            }

            SettingsSection(title: "操作") {
                SwitchRow(title: "提示音", isOn: $prefs.soundEffects)
                // 删除录屏、删除存好的截图（晾衣绳卡片上的删除、录屏缩略图上的删除）都按这个来
                SettingsRow(title: "删除文件") {
                    GlassSegmented(options: [(false, "放入废纸篓"), (true, "永久删除")],
                                  selection: $prefs.recordingDeleteForever, segmentWidth: 84)
                }
            }

            SettingsSection(title: "更新") {
                SettingsRow(title: "Velos \(UpdateChecker.currentVersion)") {
                    Button("检查更新") { UpdateChecker.shared.checkNow() }
                        .buttonStyle(CapsuleButtonStyle())
                }
                SwitchRow(title: "自动检查", isOn: $prefs.autoCheckUpdates)
            }

            SettingsSection(title: "权限") {
                SettingsRow(title: "屏幕录制") { screenRecordingButtons }
                SettingsRow(title: "麦克风") { microphoneButton }
            }
        }
        .onAppear {
            permissions.refresh()
            launchAtLogin.refresh()
        }
        // 从系统设置授权回来：重新读取权限状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    /// 屏幕录制：没授权是「授权」（第一次弹系统对话框，之后跳到系统设置）；授权了是「取消授权」（跳到系统设置里关掉）。
    /// 在系统设置里打开后往往要重启 Velos 才生效：请求过还没生效时多一个「重新启动」
    @ViewBuilder private var screenRecordingButtons: some View {
        if permissions.screenRecordingGranted {
            Button("取消授权") { permissions.openSystemSettings(.screenRecording) }
                .buttonStyle(CapsuleButtonStyle())
        } else {
            HStack(spacing: 8) {
                if permissions.needsRelaunchHint {
                    Button("重新启动") { permissions.relaunch() }
                        .buttonStyle(CapsuleButtonStyle())
                }
                Button("授权", action: permissions.requestScreenRecording)
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
            }
        }
    }

    /// 麦克风：没决定过弹系统对话框；拒绝过、要取消都只能去系统设置
    @ViewBuilder private var microphoneButton: some View {
        switch permissions.microphoneStatus {
        case .authorized:
            Button("取消授权") { permissions.openSystemSettings(.microphone) }
                .buttonStyle(CapsuleButtonStyle())
        case .restricted:
            StatusBadge(ok: false, text: "受系统限制")
        default:
            Button("授权", action: permissions.requestMicrophone)
                .buttonStyle(CapsuleButtonStyle(prominent: true))
        }
    }

    /// 开关以系统里的真实状态为准：注册失败时开关会自动弹回原位，并显示原因
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}

/// 保存文件夹：路径（点一下在访达中打开）+ 更改；改过的话多一个恢复默认
struct FolderRow: View {
    let kind: SaveLocation.Kind
    @Binding var path: String

    var body: some View {
        SettingsRow(title: "保存到") {
            HStack(spacing: 6) {
                Button { SaveLocation.revealInFinder(kind) } label: {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 180, alignment: .trailing)
                .help("在访达中打开")
                if path != SaveLocation.defaultDirectory(for: kind).path {
                    Button("恢复默认") { path = SaveLocation.defaultDirectory(for: kind).path }
                        .buttonStyle(CapsuleButtonStyle())
                }
                Button("更改…", action: choose)
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择\(kind.title)的保存位置"
        panel.directoryURL = URL(fileURLWithPath: path)
        // 作为设置窗口的二级窗口：放在设置窗口正中间
        if let parent = SettingsWindowController.currentWindow {
            panel.begin { response in
                parent.removeChildWindow(panel)
                if response == .OK, let url = panel.url { path = url.path }
            }
            panel.center(over: parent)
        } else if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
