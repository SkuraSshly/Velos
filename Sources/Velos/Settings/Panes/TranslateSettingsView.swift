import VelosOCRKit
import SwiftUI

/// 截屏翻译：文字识别、翻译、在线翻译（快捷键在「快捷键」里）
struct TranslateSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var engines = EngineSettingsModel.shared

    /// 语言选项（常用的几种；空字符串 = 跟随系统 / 自动）
    private static let languages: [TranslateLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
        .french, .german, .spanish, .russian,
    ]

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文字识别") {
                SettingsRow(title: "优先语言") {
                    languagePicker($prefs.ocrPreferredLanguage, empty: "跟随系统")
                }
                SwitchRow(title: "智能排版", isOn: $prefs.ocrSmartLayout)
                SwitchRow(title: "识别二维码", isOn: $prefs.ocrDetectsQRCodes)
            }

            SettingsSection(title: "翻译") {
                SettingsRow(title: "引擎") {
                    Picker("", selection: $prefs.defaultEngine) {
                        ForEach(engines.selectable) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "译成") {
                    languagePicker($prefs.defaultTargetLanguage, empty: "自动")
                }
                SwitchRow(title: "自动复制译文", isOn: $prefs.translateAutoCopy)
                SettingsRow(title: "朗读语速") {
                    GlassSegmented(options: [(0.42, "慢"), (0.5, "正常"), (0.57, "快")], selection: $prefs.speechRate,
                                  segmentWidth: 52)
                }
                SwitchRow(title: "窗口默认钉住", isOn: $prefs.translateWindowPinnedByDefault)
            }

            SettingsSection(title: "在线翻译") {
                OnlineEngineRows(model: engines, prompt: $prefs.llmPrompt)
            }
        }
    }

    private func languagePicker(_ selection: Binding<String>, empty: String) -> some View {
        Picker("", selection: selection) {
            Text(empty).tag("")
            Divider()
            ForEach(Self.languages, id: \.self) { Text($0.displayName).tag($0.rawValue) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// 翻译引擎设置的界面状态：Key 输入框的内容（读写钥匙串）、测试结果
@MainActor
final class EngineSettingsModel: ObservableObject {
    static let shared = EngineSettingsModel()

    @Published private var values: [String: String] = [:]
    @Published private(set) var testResults: [EngineID: (ok: Bool, text: String)] = [:]
    @Published private(set) var testing: Set<EngineID> = []
    /// 「在线翻译」里当前显示的服务商：先显示已启用的第一个，没有就显示腾讯翻译君
    @Published var selected: EngineID = {
        let enabled = Set(Preferences.shared.enabledEngines)
        return [EngineID.tencent, .volcengine, .baidu, .youdao, .deepl, .azure, .openAI, .claude]
            .first { enabled.contains($0.rawValue) } ?? .tencent
    }()

    /// 默认引擎可选的：Apple 翻译 + 已启用并填了 Key 的引擎
    var selectable: [EngineID] {
        _ = values   // 填了 Key 后刷新
        return EngineRouting.available
    }

    func isEnabled(_ engine: EngineID) -> Bool { Preferences.shared.enabledEngines.contains(engine.rawValue) }

    func setEnabled(_ engine: EngineID, _ enabled: Bool) {
        var list = Preferences.shared.enabledEngines.filter { $0 != engine.rawValue }
        if enabled { list.append(engine.rawValue) }
        Preferences.shared.enabledEngines = list
        if !enabled, Preferences.shared.defaultEngine == engine.rawValue { Preferences.shared.defaultEngine = EngineID.apple.rawValue }
        objectWillChange.send()
    }

    /// 输入框绑定。改的时候写回（Key、ID 写钥匙串，配置写设置）。
    /// 读的时候：配置照常显示；钥匙串里的 Key、ID 不读出来显示——读钥匙串内容要弹密码框（每次更新签名都不同），
    /// 已经保存的在输入框里提示「已保存」，要换就直接输入新的
    func binding(_ engine: EngineID, _ field: String) -> Binding<String> {
        let key = "\(engine.rawValue).\(field)"
        return Binding(
            get: { [weak self] in
                self?.values[key] ?? (EngineOptions.isOption(field) ? engine.credential(field) : "")
            },
            set: { [weak self] value in
                self?.values[key] = value
                engine.setCredential(value, for: field)
                self?.testResults[engine] = nil
            }
        )
    }

    /// 钥匙串里已经保存了、输入框里又没有新输入的字段：显示「已保存」提示和「清除」按钮
    func isSavedInKeychain(_ engine: EngineID, _ field: String) -> Bool {
        _ = values
        return !EngineOptions.isOption(field) && (values["\(engine.rawValue).\(field)"] ?? "").isEmpty && engine.isFilled(field)
    }

    /// 清除钥匙串里保存的这个字段
    func clear(_ engine: EngineID, _ field: String) {
        values["\(engine.rawValue).\(field)"] = ""
        engine.setCredential("", for: field)
        testResults[engine] = nil
    }

    /// 测试：把「Hello, world.」翻译成简体中文
    func test(_ engine: EngineID) {
        testing.insert(engine)
        testResults[engine] = nil
        Task { @MainActor in
            defer { testing.remove(engine) }
            do {
                let output = try await engine.translate("Hello, world.", from: .english, to: .simplifiedChinese)
                testResults[engine] = (true, "可以使用：Hello, world. → \(output)")
            } catch {
                testResults[engine] = (false, error.localizedDescription)
            }
        }
    }
}

/// 需要 Key 的在线引擎：先选服务商，下面是它的开关、Key 和测试；可以逐个启用多个。
/// 启用后才会联网，原文只发给启用的服务商，Key 存在钥匙串里
private struct OnlineEngineRows: View {
    @ObservedObject var model: EngineSettingsModel
    @Binding var prompt: String

    /// 翻译服务（免费额度多的在前）和大模型
    static let services: [EngineID] = [.tencent, .volcengine, .baidu, .youdao, .deepl, .azure]
    static let models: [EngineID] = [.openAI, .claude]

    var body: some View {
        let engine = model.selected
        SettingsRow(title: "服务商") {
            Picker("", selection: $model.selected) {
                Section("翻译服务") {
                    ForEach(Self.services) { Text(label($0)).tag($0) }
                }
                Section("大模型") {
                    ForEach(Self.models) { Text(label($0)).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        SwitchRow(title: "启用", isOn: Binding(get: { model.isEnabled(engine) }, set: { model.setEnabled(engine, $0) }))
        ForEach(engine.fields, id: \.key) { field in
            SettingsRow(title: field.label) {
                let saved = model.isSavedInKeychain(engine, field.key)
                HStack(spacing: 6) {
                    Group {
                        if field.secret {
                            SecureField(saved ? "已保存" : field.placeholder, text: model.binding(engine, field.key))
                        } else {
                            TextField(saved ? "已保存" : field.placeholder, text: model.binding(engine, field.key))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 210)
                    if saved {
                        Button("清除") { model.clear(engine, field.key) }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
            }
        }
        SettingsRow(title: "测试", caption: model.testResults[engine].map { ($0.ok ? "✓ " : "⚠️ ") + $0.text }) {
            HStack(spacing: 10) {
                if let url = engine.consoleURL {
                    Link("申请 Key", destination: url)
                        .font(.system(size: 12))
                }
                Button(model.testing.contains(engine) ? "测试中…" : "测试") { model.test(engine) }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(model.testing.contains(engine) || !engine.hasCredentials)
            }
        }
        if engine.isLLM {
            LLMPromptEditor(prompt: $prompt)
        }
    }

    private func label(_ engine: EngineID) -> String {
        model.isEnabled(engine) ? "\(engine.displayName)  ✓" : engine.displayName
    }
}

/// 大模型翻译的提示词：留空用默认的；{source}、{target} 会换成原文语言、目标语言
private struct LLMPromptEditor: View {
    @Binding var prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("提示词")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink)
                Spacer()
                if !prompt.isEmpty {
                    Button("恢复默认") { prompt = "" }
                        .buttonStyle(CapsuleButtonStyle())
                }
            }
            TextEditor(text: Binding(get: { prompt.isEmpty ? LLMTranslation.defaultPrompt : prompt },
                                     set: { prompt = $0 == LLMTranslation.defaultPrompt ? "" : $0 }))
                .font(.system(size: 12))
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .frame(height: 96)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.glassTrack.opacity(0.6)))
        }
        .padding(12)
    }
}
