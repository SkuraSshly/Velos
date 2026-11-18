import AppKit
import AVFoundation
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 最近的截图，也就是晾衣绳上挂的东西。
///
/// - 只存在本机：~/Library/Application Support/<Velos 的标识>/History，每张一个无损 PNG 加一个小缩略图
/// - 录屏也挂上：存一个指向录屏文件的替身（符号链接），取下时只删替身，录屏文件不动
/// - 别处来的图（剪贴板、拖到屏幕顶部）存一份 PNG，和截图一样
/// - 钉在绳上的（pinned.json 里记着文件名）不会因为数量超了被挤掉
/// - 保留多少张：晾衣绳设置里的数量（至少 20 张）
/// - 不占内存：平时不读取，只在放下晾衣绳时读缩略图
/// - 设置里关掉晾衣绳时，整个文件夹清空
/// - 文件名就是时间和缩放倍数，例如 20261114-140301-123@2x.png，不另存索引
@MainActor
final class ScreenshotHistory {
    static let shared = ScreenshotHistory()

    /// 最少保留几张
    nonisolated static let limit = 20
    /// 缩略图最长边（像素）：晾衣绳上「大」的卡片约 200 点宽，2x 屏上要 400 像素左右才清楚；菜单里再缩小显示
    nonisolated static let thumbnailSize = 420

    /// 保留几张（钉住的不算）：晾衣绳设置里选了多于 20 张时按那个数，否则 20 张
    nonisolated static var retention: Int {
        max(limit, AppIdentity.defaults.integer(forKey: "clotheslineKeep"))
    }

    /// 最近截图变了（新存了一张、取下、清空）：晾衣绳收到后重新读一遍
    static let didChange = Notification.Name("VelosScreenshotHistoryDidChange")

    nonisolated private static func postChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    struct Entry: Equatable {
        let url: URL
        let date: Date
        let scale: CGFloat
        /// 钉在绳上：不会被新的挤掉
        var pinned = false

        var thumbnailURL: URL { ScreenshotHistory.thumbnailURL(for: url) }
        /// 录屏视频
        var isRecording: Bool { ScreenshotHistory.recordingExtensions.contains(url.pathExtension.lowercased()) }
        /// GIF（录屏导出的、拖进来的）
        var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
        /// 存的是指向原文件的替身（录屏、GIF）：取下只删替身，原文件不动
        var isLinked: Bool { isRecording || isGIF }
        /// 真正的文件：替身指向的那个文件
        var fileURL: URL { isLinked ? url.resolvingSymlinksInPath() : url }
    }

    nonisolated static let recordingExtensions: Set<String> = ["mov", "mp4"]
    /// 存成替身的（不转成 PNG：视频不是图片，GIF 转了就不动了）
    nonisolated static let linkedExtensions: Set<String> = ["mov", "mp4", "gif"]
    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp", "bmp"]

    private var observer: AnyCancellable?

    #if DEBUG
    /// 自测：历史存到这里，不碰正式的历史文件夹
    nonisolated(unsafe) static var debugDirectory: URL?
    #endif

    private init() {}

    /// 关掉晾衣绳时清空（设置进程里改的也会同步过来）
    func start() {
        observer = Preferences.shared.$clotheslineEnabled.removeDuplicates().dropFirst().sink { enabled in
            if !enabled { ScreenshotHistory.shared.clear() }
        }
    }

    nonisolated static var directory: URL {
        #if DEBUG
        if let debugDirectory { return debugDirectory }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(AppIdentity.mainBundleID, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    // MARK: - 记录

    /// 记下一张截图（在后台编码、写文件）。没开晾衣绳时什么都不做
    func record(_ image: CGImage, scale: CGFloat, date: Date = Date()) {
        guard Preferences.shared.historyEnabled else { return }
        Task.detached(priority: .utility) {
            guard let png = ImageEncoder.encode(image, format: .png, quality: 1, scale: scale) else { return }
            Self.write(png: png, image: image, scale: scale, date: date)
        }
    }

    /// 后台：写入 PNG 和缩略图，删掉超出数量的旧截图。已经有编码好的 PNG 时直接用（截图输出流程里调用）
    nonisolated static func write(png: Data, image: CGImage, scale: CGFloat, date: Date) {
        // 几张同时写（截图、剪贴板、拖进来）：排队一张一张来，免得「同一张只挂一次」的记录写乱
        writeLock.lock()
        defer { writeLock.unlock() }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = fileName(date: date, scale: scale)
            // 同一张图（像素完全一样）已经挂着：不再挂一份，把原来那张挪到最新（移到绳子最右边）
            let hash = pixelHash(image)
            var hashes = loadHashes()
            if let hash, let existing = hashes.first(where: { $0.value == hash })?.key,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(existing).path) {
                if existing != name { renameEntry(existing, to: name, hashes: &hashes) }
                saveHashes(hashes)
                Log.capture.notice("最近截图：这张已经挂着，挪到最新")
                postChange()
                return
            }
            let url = directory.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            let factor = CGFloat(max(image.width, image.height)) / CGFloat(thumbnailSize)
            if let thumbnail = ImageEncoder.downscaled(image, by: max(1, factor)),
               let data = ImageEncoder.encode(thumbnail, format: .png, quality: 1, scale: 2) {
                try data.write(to: thumbnailURL(for: url), options: .atomic)
            }
            if let hash { hashes[name] = hash }
            prune()
            // 只留还在的文件的记录
            let names = Set((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            saveHashes(hashes.filter { names.contains($0.key) })
            postChange()
        } catch {
            Log.capture.error("最近截图写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 同一张图只挂一次（移植自 Picline 的去重：按解码后的像素精确比较）

    nonisolated private static let writeLock = NSLock()
    nonisolated private static var hashesFile: URL { directory.appendingPathComponent("hashes.json") }

    /// 文件名 → 像素指纹
    nonisolated private static func loadHashes() -> [String: String] {
        guard let data = try? Data(contentsOf: hashesFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    nonisolated private static func saveHashes(_ hashes: [String: String]) {
        try? JSONEncoder().encode(hashes).write(to: hashesFile, options: .atomic)
    }

    /// 像素指纹：画成统一的 sRGB 8 位 RGBA 再算 SHA-256（不管原来是 PNG、TIFF 还是 JPEG，像素一样指纹就一样；
    /// 裁剪过、标注过、重新压缩过的算不同的图）
    // MARK: - 存成的文件（右键「在访达中显示」用）

    /// 截图存到截图文件夹的哪个文件：按像素指纹记（同一张图换了名字也找得到；改过的图指纹变了，就不再算存过）
    nonisolated private static var savedFilesFile: URL { directory.appendingPathComponent("saved.json") }

    /// 记下：这张图存成了这个文件
    nonisolated static func noteSaved(_ file: URL, image: CGImage) {
        guard let hash = pixelHash(image) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        // 已经不在的记录不在这里清：留给 pruneDeletedFiles 认出「这张存的文件被删了」，把绳上的也拿掉
        var saved = loadSavedFiles()
        saved[hash] = file.path
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: savedFilesFile, options: .atomic)
    }

    nonisolated private static func loadSavedFiles() -> [String: String] {
        (try? Data(contentsOf: savedFilesFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// 在访达里删了（移到废纸篓、永久删除）存好的文件：绳上对应的那张也拿掉。
    /// 录屏、GIF：它本身不在了；截图：存到截图文件夹的那张不在了（没存过的截图不受影响）。
    /// - Parameter notify: 要不要通知绳子重新读（绳子自己读之前顺手清理时不用）
    /// - Returns: 拿掉了几张
    @discardableResult
    func pruneDeletedFiles(notify: Bool = true) -> Int {
        let gone = deletedEntries()
        guard !gone.isEmpty else { return 0 }
        // 记录里去掉已经不在的文件
        Self.writeLock.lock()
        let saved = Self.loadSavedFiles().filter { FileManager.default.fileExists(atPath: $0.value) }
        try? JSONEncoder().encode(saved).write(to: Self.savedFilesFile, options: .atomic)
        Self.writeLock.unlock()
        Log.capture.notice("晾衣绳：\(gone.count) 个文件在访达里被删了，绳上的也拿掉")
        forget(gone, notify: notify)
        return gone.count
    }

    /// 存好的文件已经不在了的那几张（只是找出来，不动它们）
    func deletedEntries() -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else { return [] }
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let pinned = Set(Self.pinnedNames())
        let all = files.compactMap(Self.parse).map { entry in
            var entry = entry
            entry.pinned = pinned.contains(entry.url.lastPathComponent)
            return entry
        }
        var gone = all.filter { $0.isLinked && !exists($0.fileURL.path) }
        let missing = Set(Self.loadSavedFiles().filter { !exists($0.value) }.keys)
        if !missing.isEmpty {
            let hashes = Self.loadHashes()
            gone += all.filter { !$0.isLinked && hashes[$0.url.lastPathComponent].map(missing.contains) == true }
        }
        return gone
    }

    /// 这一张真正存在电脑上的文件：录屏、GIF 是它本身；截图是存到截图文件夹的那个（没存过、或存的文件被删了就是 nil）
    func savedFile(for entry: Entry) -> URL? {
        savedFiles(for: [entry])[entry.url]
    }

    /// 一次查好几张（只读一遍记录）：键是绳上那张的 url
    func savedFiles(for entries: [Entry]) -> [URL: URL] {
        let hashes = Self.loadHashes()
        let saved = Self.loadSavedFiles()
        var result: [URL: URL] = [:]
        for entry in entries {
            let file: URL?
            if entry.isLinked {
                file = entry.fileURL
            } else {
                file = hashes[entry.url.lastPathComponent].flatMap { saved[$0] }.map { URL(fileURLWithPath: $0) }
            }
            if let file, FileManager.default.fileExists(atPath: file.path) { result[entry.url] = file }
        }
        return result
    }

    nonisolated static func pixelHash(_ image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hasher = SHA256()
        withUnsafeBytes(of: (width, height)) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: data, count: width * height * 4))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 改过的图（快速查看里标记、旋转）换新的指纹
    nonisolated static func updateHash(for name: String, image: CGImage) {
        writeLock.lock()
        defer { writeLock.unlock() }
        var hashes = loadHashes()
        hashes[name] = pixelHash(image)
        saveHashes(hashes)
    }

    /// 把已有的一张改成新的文件名（时间变成现在，挪到最新）；钉住的照样钉住
    nonisolated private static func renameEntry(_ old: String, to new: String, hashes: inout [String: String]) {
        let manager = FileManager.default
        let oldURL = directory.appendingPathComponent(old), newURL = directory.appendingPathComponent(new)
        guard (try? manager.moveItem(at: oldURL, to: newURL)) != nil else { return }
        try? manager.moveItem(at: thumbnailURL(for: oldURL), to: thumbnailURL(for: newURL))
        if let hash = hashes.removeValue(forKey: old) { hashes[new] = hash }
        var pinned = pinnedNames()
        if let index = pinned.firstIndex(of: old) {
            pinned[index] = new
            try? JSONEncoder().encode(pinned).write(to: pinnedFile, options: .atomic)
        }
    }

    /// 只留最新的 retention 张（钉住的不算、也不删）
    nonisolated private static func prune() {
        for old in entries().filter({ !$0.pinned }).dropFirst(retention) {
            try? FileManager.default.removeItem(at: old.url)
            try? FileManager.default.removeItem(at: old.thumbnailURL)
        }
    }

    // MARK: - 别处来的图、录屏

    /// 挂上一个文件（拖到屏幕顶部、剪贴板里复制的图片文件）：图片存一份 PNG，录屏、GIF 存一个替身
    func record(file url: URL) {
        guard Preferences.shared.historyEnabled else { return }
        let ext = url.pathExtension.lowercased()
        if Self.linkedExtensions.contains(ext) {
            recordLinked(url)
        } else if Self.imageExtensions.contains(ext), let data = try? Data(contentsOf: url) {
            record(imageData: data)
        }
    }

    /// 挂上一张图片的数据（剪贴板、拖进来的图片）。缩放倍数按图里写的 DPI（144 = 2x），没写就是 1x
    func record(imageData data: Data) {
        guard Preferences.shared.historyEnabled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        record(image, scale: max(1, (dpi / 72).rounded()))
    }

    /// 录完的视频（导出的 GIF）也挂上：存一个指向它的替身和第一帧的缩略图
    func recordLinked(_ video: URL) {
        guard Preferences.shared.historyEnabled else { return }
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let name = Self.fileName(date: Date(), scale: 1).replacingOccurrences(of: ".png", with: "." + video.pathExtension.lowercased())
                let link = Self.directory.appendingPathComponent(name)
                try manager.createSymbolicLink(at: link, withDestinationURL: video)
                if let frame = await Self.firstFrame(of: video),
                   let data = ImageEncoder.encode(frame, format: .png, quality: 1, scale: 2) {
                    try data.write(to: Self.thumbnailURL(for: link), options: .atomic)
                }
                Self.prune()
                Self.postChange()
            } catch {
                Log.capture.error("最近截图：挂上录屏失败 \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 视频或 GIF 的第一帧（默认缩小到缩略图大小；录屏飞上绳时要清楚一些，传更大的 maxPixels）
    nonisolated static func firstFrame(of url: URL, maxPixels: Int = thumbnailSize) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? await generator.image(at: .zero).image
    }

    // MARK: - 钉在绳上

    nonisolated private static var pinnedFile: URL { directory.appendingPathComponent("pinned.json") }

    nonisolated private static func pinnedNames() -> [String] {
        guard let data = try? Data(contentsOf: pinnedFile) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// 钉住 / 取消钉住：钉住的挂在绳子最左边，不会被新的挤掉
    /// - Parameter prunes: 取消钉住后按数量删掉多出来的（拿去暂存撤销时不删：它们马上就搬走了）
    func setPinned(_ entries: [Entry], _ pinned: Bool, prunes: Bool = true) {
        var names = Self.pinnedNames()
        for entry in entries {
            let name = entry.url.lastPathComponent
            names.removeAll { $0 == name }
            if pinned { names.append(name) }
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(names).write(to: Self.pinnedFile, options: .atomic)
        if !pinned, prunes { Self.prune() }
        Self.postChange()
    }

    /// 绳上的东西变了（撤销取下等在外面改了文件夹）：通知晾衣绳重新读
    static func notifyChanged() { postChange() }

    // MARK: - 读取

    /// 最新的在前（录屏的替身指向的文件已经不在了就不列出来）
    nonisolated static func entries() -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let pinned = Set(pinnedNames())
        // 指向的录屏已经被删了的替身也列出来：它的卡片要先在绳上「被拿掉」给你看（见 ClotheslineController.filesChanged），
        // 之后才删掉替身
        return files.compactMap(parse)
            .map { entry in
                var entry = entry
                entry.pinned = pinned.contains(entry.url.lastPathComponent)
                return entry
            }
            .sorted { $0.date > $1.date }
    }

    /// 钉住的，按钉上的先后
    nonisolated static func pinnedOrder() -> [String] { pinnedNames() }

    /// 解码出原图（钉图用）；录屏没有
    func image(for entry: Entry) -> CGImage? {
        guard !entry.isLinked, let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - 操作

    /// 重新复制到剪贴板（无损 PNG；录屏、GIF 复制成文件，粘贴到聊天软件就是这个视频 / 动图）
    func copy(_ entry: Entry) {
        var pasteboard = NSPasteboard.general
        #if DEBUG
        if ScreenshotOutput.dryRun { pasteboard = NSPasteboard(name: .init("local.velos.selftest")) }
        #endif
        if entry.isLinked {
            let item = NSPasteboardItem()
            item.setString(entry.fileURL.absoluteString, forType: .fileURL)
            item.setString("1", forType: ClipboardWatcher.ownType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return
        }
        guard let data = try? Data(contentsOf: entry.url) else { return }
        ClipboardWriter.write(png: data, to: pasteboard, onFirstRead: nil)
        Log.capture.notice("最近截图：已重新复制")
    }

    /// 钉到鼠标所在屏幕的中央，原像素、原大小（只有比整块屏幕还大才缩小，和普通钉图一样）
    @discardableResult
    func pin(_ entry: Entry) -> PinWindow? {
        guard let capture = capture(of: entry) else { return nil }
        return PinManager.shared.pin(capture)
    }

    /// 这张截图当作「刚截的」：原像素、原大小，位置在鼠标所在屏幕的正中（按整块屏幕居中，
    /// 不是菜单栏和程序坞之间那块：那块放不下一张整屏截图，会被缩小）
    func capture(of entry: Entry) -> CapturedImage? {
        guard let image = image(for: entry) else { return nil }
        let size = CGSize(width: CGFloat(image.width) / entry.scale, height: CGFloat(image.height) / entry.scale)
        let screen = (NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let origin = CGPoint(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded())
        return CapturedImage(image: image, scale: entry.scale, sourceRect: CGRect(origin: origin, size: size))
    }

    /// 清空（关掉晾衣绳时）
    func clear() {
        let directory = Self.directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
            Self.postChange()
        }
        Log.capture.notice("最近截图：已清空")
    }

    /// 取下一张（晾衣绳上点 ✕、拖到废纸篓）：原图移到废纸篓（还能从废纸篓放回来），缩略图直接删掉；
    /// 录屏只删替身，录屏文件本身不动
    func remove(_ entries: [Entry]) {
        if entries.contains(where: \.pinned) { setPinned(entries.filter(\.pinned), false) }
        for entry in entries {
            if entry.isLinked {
                try? FileManager.default.removeItem(at: entry.url)
                try? FileManager.default.removeItem(at: entry.thumbnailURL)
                continue
            }
            #if DEBUG
            // 自测的图直接删掉，不放进用户的废纸篓
            if Self.debugDirectory != nil {
                try? FileManager.default.removeItem(at: entry.url)
                try? FileManager.default.removeItem(at: entry.thumbnailURL)
                continue
            }
            #endif
            try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            try? FileManager.default.removeItem(at: entry.thumbnailURL)
        }
        if !entries.isEmpty {
            Log.capture.notice("最近截图：取下 \(entries.count) 张")
            Self.postChange()
        }
    }

    /// 指向这些文件的替身（晾衣绳上的录屏、GIF 卡片）全部拿掉
    func forgetLinks(to files: [URL]) {
        let targets = Set(files.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let links = Self.entries().filter { $0.isLinked && targets.contains($0.fileURL.standardizedFileURL) }
        if !links.isEmpty { forget(links) }
    }

    /// 删除存在电脑上的文件（录屏、GIF 本身；截图存到截图文件夹的那张），绳上这张也一起拿掉。
    /// 进废纸篓还是永久删除，按设置里选的
    func deleteOriginals(_ entries: [Entry]) {
        let files = savedFiles(for: entries)
        let targets = entries.filter { files[$0.url] != nil }
        guard !targets.isEmpty else { return }
        for entry in targets where entry.isLinked { VideoPreviewWindowController.close(for: entry.fileURL) }
        RecordingFiles.delete(targets.compactMap { files[$0.url] })
        forget(targets)
    }

    /// 拖到别处去了（发出去、存进了文件夹）：这张从「最近截图」里删掉，不进废纸篓（拖出去的是副本，那边已经有了）
    func forget(_ entries: [Entry], notify: Bool = true) {
        if entries.contains(where: \.pinned) { setPinned(entries.filter(\.pinned), false, prunes: false) }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: entry.thumbnailURL)
        }
        if notify, !entries.isEmpty { Self.postChange() }
    }

    /// 在快速查看里标记、旋转过：把改好的图写回这张截图，重新生成缩略图（晾衣绳上的卡片跟着换）
    func replace(_ entry: Entry, withContentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = ImageEncoder.encode(image, format: .png, quality: 1, scale: entry.scale) else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try png.write(to: entry.url, options: .atomic)
                let factor = CGFloat(max(image.width, image.height)) / CGFloat(Self.thumbnailSize)
                if let thumbnail = ImageEncoder.downscaled(image, by: max(1, factor)),
                   let data = ImageEncoder.encode(thumbnail, format: .png, quality: 1, scale: 2) {
                    try data.write(to: entry.thumbnailURL, options: .atomic)
                }
                Self.updateHash(for: entry.url.lastPathComponent, image: image)
                Log.capture.notice("最近截图：快速查看里改过，已保存")
                await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: entry.url) }
            } catch {
                Log.capture.error("最近截图：保存修改失败 \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 拖到别的 App、复制成文件时用的副本：文件名和保存的截图一样（「截图 2026-11-14 14.03.01.png」），
    /// 放在拖拽用的临时文件夹里（Velos 启动时清理一天前的）
    func sharingFile(for entry: Entry) -> URL? {
        if entry.isLinked { return entry.fileURL }
        let directory = CapturedImage.sharingDirectory
        let url = directory.appendingPathComponent(SaveLocation.fileName(prefix: "截图", fileExtension: "png", date: entry.date))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: entry.url, to: url)
            return url
        } catch {
            Log.capture.error("最近截图：准备拖拽文件失败 \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 文件名

    nonisolated private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    nonisolated static func fileName(date: Date, scale: CGFloat) -> String {
        "\(formatter.string(from: date))@\(Int(scale.rounded()))x.png"
    }

    nonisolated static func thumbnailURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("thumb")
    }

    /// 从文件名读出时间和缩放倍数；缩略图和别的文件返回 nil
    nonisolated static func parse(_ url: URL) -> Entry? {
        guard url.pathExtension == "png" || linkedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "@")
        guard parts.count == 2, parts[1].hasSuffix("x"), let scale = Int(parts[1].dropLast()), scale > 0,
              let date = formatter.date(from: String(parts[0])) else { return nil }
        return Entry(url: url, date: date, scale: CGFloat(scale))
    }
}

/// 删除录屏文件：按设置放进废纸篓（默认）或永久删除。晾衣绳上的删除、录屏缩略图上的删除都走这里
@MainActor
enum RecordingFiles {
    static var deletesForever: Bool { Preferences.shared.recordingDeleteForever }

    static func delete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 文件删了，晾衣绳上指向它的卡片也一起拿掉（不管是从哪里删的）
        ScreenshotHistory.shared.forgetLinks(to: urls)
        if deletesForever {
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Log.capture.error("永久删除失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            Log.capture.notice("永久删除了 \(urls.count) 个录屏文件")
        } else {
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { Log.capture.error("移到废纸篓失败：\(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// 按钮、菜单上的说法
    static var actionTitle: String { deletesForever ? "永久删除" : "删除（移到废纸篓）" }
}
