// 检查更新的做法参考 Picline（https://github.com/Xinguangcuican/Picline）的 UpdateChecker，MIT 许可证。
// 改动：默认不自动检查（Velos 默认不联网），自动检查要在设置里自己打开。

import AppKit

/// 检查更新：去 GitHub 问一次 Velos 最新发布的版本号，比现在装的新就提示去下载。
///
/// - 只发一个普通的 HTTPS 请求到 api.github.com（GitHub 能看到的只有你的网络地址），不带任何关于你、你的截图的信息
/// - 设置 › 通用 › 「检查更新」按钮：当场问一次，有没有新版本、连不连得上都告诉你
/// - 「自动检查更新」默认关；打开后 Velos 启动 20 秒后和之后每 24 小时问一次，有新版本时提示一次（同一个版本只提示一次）
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let latestURL = URL(string: "https://api.github.com/repos/SkuraSshly/Velos/releases/latest")!
    private static let notifiedKey = "updateNotifiedVersion"
    private var timer: Timer?
    private var checking = false

    private init() {}

    struct Release {
        let version: String
        let page: URL
    }

    enum Outcome {
        case newer(Release)
        case upToDate(String)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - 自动检查（默认关）

    /// Velos 启动时调用：开着「自动检查更新」才定时检查；设置里改了随时生效
    func start() {
        apply(Preferences.shared.autoCheckUpdates)
        observer = Preferences.shared.$autoCheckUpdates.removeDuplicates().dropFirst().sink { enabled in
            DispatchQueue.main.async { UpdateChecker.shared.apply(enabled) }
        }
    }

    private var observer: Any?

    private func apply(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        // 启动后等 20 秒（不和启动抢资源），之后每 24 小时
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard Preferences.shared.autoCheckUpdates else { return }
            self?.checkQuietly()
        }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkQuietly() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 自动检查：只在有新版本、而且这个版本还没提示过时弹出
    private func checkQuietly() {
        Task {
            guard case .newer(let release) = await Self.fetch(),
                  AppIdentity.defaults.string(forKey: Self.notifiedKey) != release.version else { return }
            AppIdentity.defaults.set(release.version, forKey: Self.notifiedKey)
            Self.presentNewer(release)
        }
    }

    // MARK: - 手动检查（设置里的按钮）

    /// 当场问一次并告诉结果
    func checkNow() {
        guard !checking else { return }
        checking = true
        Task {
            let outcome = await Self.fetch()
            checking = false
            switch outcome {
            case .newer(let release):
                Self.presentNewer(release)
            case .upToDate(let version):
                Self.alert("已经是最新版本", "现在用的 Velos \(version) 就是最新的。")
            case .failed(let reason):
                Self.alert("没能检查更新", reason)
            }
        }
    }

    // MARK: - 请求

    static func fetch() async -> Outcome {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Velos", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                return .failed("GitHub 返回的内容看不懂，稍后再试，或直接去 GitHub 的发布页看看。")
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            Log.capture.notice("检查更新：最新 \(latest, privacy: .public)，现在 \(currentVersion, privacy: .public)")
            return isNewer(latest, than: currentVersion) ? .newer(Release(version: latest, page: page)) : .upToDate(currentVersion)
        } catch {
            return .failed("连不上 GitHub：\(error.localizedDescription)")
        }
    }

    /// 版本号按数字逐段比较：2.10 比 2.9 新，2.4.2 比 2.4 新
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 提示

    private static func presentNewer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Velos \(release.version) 有新版本了"
        alert.informativeText = "现在用的是 \(currentVersion)。点「去下载」打开 GitHub 的发布页，下载 dmg 后拖进「应用程序」替换即可，设置和权限都会保留。"
        alert.addButton(withTitle: "去下载")
        alert.addButton(withTitle: "以后再说")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
