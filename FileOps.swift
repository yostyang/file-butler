import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreServices

let accentA = Color(red: 0.42, green: 0.36, blue: 0.98), accentB = Color(red: 0.18, green: 0.70, blue: 0.96)
let accentGrad = LinearGradient(colors: [accentA, accentB], startPoint: .topLeading, endPoint: .bottomTrailing)
let fdaURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

struct FileItem: Hashable {
    let url: URL; let name: String; let isDir: Bool; let isPackage: Bool
    let size: Int64; let modified: Date?; let created: Date?; let kind: String; let hidden: Bool
    let tags: [String]
    var isFolderLike: Bool { isDir && !isPackage }
}
enum SortKey: String, CaseIterable { case name, kind, date, size
    var title: String { switch self { case .name: return "名称"; case .kind: return "种类"; case .date: return "修改日期"; case .size: return "大小" } } }
enum TransferMode { case auto, copy, move }
enum ViewMode: String, CaseIterable { case icon, list, column, gallery
    var title: String { switch self { case .icon: return "图标"; case .list: return "列表"; case .column: return "分栏"; case .gallery: return "画廊" } }
    var symbol: String { switch self { case .icon: return "square.grid.2x2"; case .list: return "list.bullet"; case .column: return "rectangle.split.3x1"; case .gallery: return "rectangle.bottomthird.inset.filled" } } }
enum GroupKey: String, CaseIterable { case none, name, kind, date, size, tag
    var title: String { switch self { case .none: return "无"; case .name: return "名称"; case .kind: return "种类"; case .date: return "修改日期"; case .size: return "大小"; case .tag: return "标签" } } }
enum SearchScope: String, Codable, CaseIterable { case folder, subfolders, mac
    var title: String { switch self { case .folder: return "当前文件夹"; case .subfolders: return "包括子文件夹"; case .mac: return "这台 Mac" } } }
/// 搜索匹配方式：访达的「名称匹配」/「内容包含」（内容必须走 Spotlight）
enum SearchMatch: String, Codable, CaseIterable { case name, contents
    var title: String { switch self { case .name: return "名称"; case .contents: return "内容" } } }

let listKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isHiddenKey, .tagNamesKey]

// 种类名称按文件类型缓存：比逐个文件读取 localizedTypeDescription 快得多
private let kindLock = NSLock()
private var kindCache: [String: String] = [:]
func kindName(_ t: UTType?, isDir: Bool, isPackage: Bool) -> String {
    if isDir && !isPackage { return "文件夹" }
    guard let t = t else { return "文稿" }
    kindLock.lock(); defer { kindLock.unlock() }
    if let k = kindCache[t.identifier] { return k }
    let k = t.localizedDescription ?? t.preferredFilenameExtension.map { "\($0.uppercased()) 文件" } ?? "文稿"
    kindCache[t.identifier] = k
    return k
}

let listKeySet = Set(listKeys)
func makeItem(_ raw: URL) -> FileItem { makeItem(raw, standardize: true) }
func makeItem(_ raw: URL, standardize: Bool) -> FileItem {
    var u = standardize ? raw.standardizedFileURL : raw
    // 只有单独传入的旧 URL（standardize == true）才需先清缓存；
    // contentsOfDirectory(includingPropertiesForKeys:) 刚通过 getattrlistbulk 预取的 URL（standardize == false）直接用内核预取结果，避免退化为逐个文件重读磁盘
    if standardize { u.removeAllCachedResourceValues() }
    let v = try? u.resourceValues(forKeys: listKeySet)
    u.removeAllCachedResourceValues()   // 不让每个 URL 一直挂着属性缓存，省内存
    let isDir = v?.isDirectory ?? false, isPkg = v?.isPackage ?? false
    return FileItem(url: u, name: u.lastPathComponent, isDir: isDir, isPackage: isPkg,
                    size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, created: v?.creationDate,
                    kind: kindName(v?.contentType, isDir: isDir, isPackage: isPkg), hidden: v?.isHidden ?? u.lastPathComponent.hasPrefix("."), tags: v?.tagNames ?? [])
}

/// 在后台线程调用：列出目录并读取需要的属性。
func loadDirectory(_ p: URL, hidden: Bool) -> (items: [FileItem], err: String?, denied: Bool) {
    do {
        let dir = p.standardizedFileURL
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: listKeys, options: hidden ? [] : [.skipsHiddenFiles])
        // 目录本身已规范化，子项不必再逐个 standardize
        return (urls.map { makeItem($0, standardize: false) }, nil, false)
    } catch { return ([], error.localizedDescription, isPermissionError(error)) }
}

func sortItems(_ a: [FileItem], key: SortKey, asc: Bool) -> [FileItem] {
    guard a.count > 1 else { return a }
    return a.sorted { x, y in
        let r: Bool
        switch key {
        case .name:
            r = x.name.localizedStandardCompare(y.name) == .orderedAscending
        case .size:
            if x.size != y.size { r = x.size < y.size }
            else { r = x.name.localizedStandardCompare(y.name) == .orderedAscending }
        case .date:
            let dx = x.modified ?? .distantPast, dy = y.modified ?? .distantPast
            if dx != dy { r = dx < dy }
            else { r = x.name.localizedStandardCompare(y.name) == .orderedAscending }
        case .kind:
            if x.kind != y.kind { r = x.kind.localizedStandardCompare(y.kind) == .orderedAscending }
            else { r = x.name.localizedStandardCompare(y.name) == .orderedAscending }
        }
        return asc ? r : !r
    }
}

// MARK: tags
let standardTags: [(String, NSColor)] = [("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow), ("绿色", .systemGreen), ("蓝色", .systemBlue), ("紫色", .systemPurple), ("灰色", .systemGray)]
let englishTags = ["Red": 0, "Orange": 1, "Yellow": 2, "Green": 3, "Blue": 4, "Purple": 5, "Gray": 6, "Grey": 6]
func tagColor(_ name: String) -> NSColor? {
    if let i = standardTags.firstIndex(where: { $0.0 == name }) { return standardTags[i].1 }
    if let i = englishTags[name] { return standardTags[i].1 }
    return nil
}

// MARK: grouping
func groupItems(_ items: [FileItem], by k: GroupKey) -> [(String, [FileItem])] {
    guard k != .none else { return [("", items)] }
    let cal = Calendar.current, now = Date()
    let nowTs = now.timeIntervalSince1970
    let startOfToday = cal.startOfDay(for: now).timeIntervalSince1970
    let startOfYesterday = startOfToday - 86400
    let sevenDaysAgo = nowTs - 7 * 86400
    let thirtyDaysAgo = nowTs - 30 * 86400
    let curYear = cal.component(.year, from: now)
    let startOfYear = (cal.date(from: DateComponents(year: curYear, month: 1, day: 1)) ?? now).timeIntervalSince1970
    func label(_ it: FileItem) -> (String, Int) {
        switch k {
        case .none: return ("", 0)
        case .name:
            if let ch = it.name.first, ch.isLetter { return (String(ch).uppercased(), 0) }
            return ("#", 0)
        case .kind: return (it.isFolderLike ? "文件夹" : (it.kind.isEmpty ? "其他" : it.kind), it.isFolderLike ? 0 : 1)
        case .date:
            guard let d = it.modified else { return ("未知", 9) }
            let ts = d.timeIntervalSince1970
            if ts >= startOfToday { return ("今天", 0) }
            if ts >= startOfYesterday { return ("昨天", 1) }
            if ts > sevenDaysAgo { return ("过去 7 天", 2) }
            if ts > thirtyDaysAgo { return ("过去 30 天", 3) }
            if ts >= startOfYear { return ("今年早些时候", 4) }
            let y = cal.component(.year, from: d)
            return ("\(y) 年", 10000 - y)
        case .size:
            if it.isFolderLike { return ("文件夹", 0) }
            let s = it.size
            if s >= 1 << 30 { return ("大于 1 GB", 1) }
            if s >= 100 << 20 { return ("100 MB – 1 GB", 2) }
            if s >= 1 << 20 { return ("1 MB – 100 MB", 3) }
            if s >= 100 << 10 { return ("100 KB – 1 MB", 4) }
            return ("小于 100 KB", 5)
        case .tag: return it.tags.first.map { ($0, 0) } ?? ("无标签", 1)
        }
    }
    var dict: [String: [FileItem]] = [:], rank: [String: Int] = [:]
    for it in items { let (l, r) = label(it); dict[l, default: []].append(it); rank[l] = r }
    return dict.keys.sorted { (rank[$0]!, $0) < (rank[$1]!, $1) }.map { ($0, dict[$0]!) }
}

let byteFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
func fmtBytes(_ b: Int64) -> String { byteFmt.string(fromByteCount: b) }
let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
func fmtDate(_ d: Date?) -> String { d.map { dateFmt.string(from: $0) } ?? "--" }

func isPermissionError(_ e: Error) -> Bool {
    let n = e as NSError
    if n.domain == NSCocoaErrorDomain && (n.code == NSFileReadNoPermissionError || n.code == NSFileWriteNoPermissionError) { return true }
    if let u = n.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain, u.code == Int(EPERM) || u.code == Int(EACCES) { return true }
    return false
}
func sameVolume(_ a: URL, _ b: URL) -> Bool {
    let k: Set<URLResourceKey> = [.volumeIdentifierKey]
    guard let x = (try? a.resourceValues(forKeys: k))?.volumeIdentifier, let y = (try? b.resourceValues(forKeys: k))?.volumeIdentifier else { return false }
    return x.isEqual(y)
}
func uniqueCopyURL(in dir: URL, name: String) -> URL { uniqueURL(in: dir, name: name, copy: true) }
func uniqueURL(in dir: URL, name: String, copy: Bool, taken: ((URL) -> Bool)? = nil) -> URL {
    let fm = FileManager.default
    let isTaken: (URL) -> Bool = taken ?? { fm.fileExists(atPath: $0.path) }
    var u = dir.appendingPathComponent(name)
    if !isTaken(u) { return u }
    var ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    if name.hasSuffix(".zip") && !copy { ext = "zip"; base = String(name.dropLast(4)) }
    var i = copy ? 1 : 2
    while true {
        let b = copy ? (i == 1 ? "\(base) 副本" : "\(base) 副本 \(i)") : "\(base) \(i)"
        u = dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)")
        if !isTaken(u) { return u }
        i += 1
    }
}
func copyPaths(_ urls: [URL]) {
    let pb = NSPasteboard.general; pb.clearContents(); pb.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
}
func freeSpace(_ u: URL) -> Int64? {
    guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
    return v.volumeAvailableCapacityForImportantUsage
}

struct FBError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
indirect enum UndoOp { case rename(URL, URL), moved([(URL, URL)]), trashed([(URL, URL)]), created([URL]), group([UndoOp]), renamedBatch([(URL, URL)]) }

// MARK: - Pure file operations (also used by --selftest)
enum FileOps {
    static let fm = FileManager.default
    /// 移到废纸篓：用系统的 trashItem（可「放回原处」、同名自动改名）。
    /// 按文件名分 4 路并行：同名的项目总在同一路里依次处理，不会在废纸篓里抢同一个名字。
    static func trash(_ urls: [URL], progress: OpProgress? = nil) -> (done: [(URL, URL)], errs: [String], perm: Bool) {
        progress?.markRunning()
        progress?.total = urls.count
        let lanes = min(4, max(1, urls.count))
        var buckets = [[Int]](repeating: [], count: lanes)
        for (i, u) in urls.enumerated() { buckets[abs(u.lastPathComponent.lowercased().hashValue) % lanes].append(i) }
        var out = [(URL?, String?, Bool)](repeating: (nil, nil, false), count: urls.count)
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob
            DispatchQueue.concurrentPerform(iterations: lanes) { k in
                for i in buckets[k] {
                    if progress?.isCancelled == true { return }
                    defer { progress?.step() }
                    do {
                        var res: NSURL?
                        try fm.trashItem(at: urls[i], resultingItemURL: &res)
                        o[i] = (res as URL?, nil, false)
                    } catch { o[i] = (nil, "「\(urls[i].lastPathComponent)」：\(error.localizedDescription)", isPermissionError(error)) }
                }
            }
        }
        var done: [(URL, URL)] = [], errs: [String] = [], perm = false
        for (i, r) in out.enumerated() {
            if let t = r.0 { done.append((urls[i], t)) }
            if let e = r.1 { errs.append(e); perm = perm || r.2 }
        }
        return (done, errs, perm)
    }
    static func newFolder(in dir: URL) throws -> URL {
        var name = "未命名文件夹", i = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "未命名文件夹 \(i)"; i += 1 }
        let u = dir.appendingPathComponent(name)
        try fm.createDirectory(at: u, withIntermediateDirectories: false)
        return u
    }
    /// 访达的「用所选项目新建文件夹」：在第一个项目所在的文件夹里新建「新建文件夹包含项目」，把所选项目移进去。
    static func newFolderWithItems(_ urls: [URL]) throws -> (folder: URL, moved: [(URL, URL)]) {
        guard let first = urls.first else { throw FBError("没有选中项目。") }
        let dir = first.deletingLastPathComponent()
        var name = "新建文件夹包含项目", i = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "新建文件夹包含项目 \(i)"; i += 1 }
        let folder = dir.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var moved: [(URL, URL)] = []
        do {
            for u in urls { let dst = folder.appendingPathComponent(u.lastPathComponent); try fm.moveItem(at: u, to: dst); moved.append((u, dst)) }
        } catch {
            for (a, b) in moved.reversed() { try? fm.moveItem(at: b, to: a) }
            try? fm.removeItem(at: folder)
            throw error
        }
        return (folder, moved)
    }
    /// 访达的「制作替身」：写入 alias（书签）文件，命名为「X 的替身」。
    static func makeAlias(_ u: URL) throws -> URL {
        let data = try u.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        let dir = u.deletingLastPathComponent()
        var name = "\(u.lastPathComponent) 的替身", i = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "\(u.lastPathComponent) 的替身 \(i)"; i += 1 }
        let dst = dir.appendingPathComponent(name)
        try URL.writeBookmarkData(data, to: dst)
        return dst
    }
    static func rename(_ u: URL, to name: String) throws -> URL {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw FBError("名称不能为空。") }
        if n.contains("/") || n.contains(":") { throw FBError("名称不能包含“/”或“:”。") }
        let dst = u.deletingLastPathComponent().appendingPathComponent(n)
        if fm.fileExists(atPath: dst.path) && dst.path.lowercased() != u.path.lowercased() { throw FBError("名称“\(n)”已被使用。请选取一个不同的名称。") }
        try fm.moveItem(at: u, to: dst)
        return dst
    }
    /// 执行撤销或重做，并生成反向操作（供重做 / 再次撤销使用）以及本次移入废纸篓的项目位置。
    static func undoWithInverse(_ op: UndoOp) throws -> (inverse: UndoOp, trashed: [URL]) {
        switch op {
        case .rename(let a, let b):
            try fm.moveItem(at: b, to: a)
            return (.rename(b, a), [])
        case .moved(let pairs):
            for (a, b) in pairs.reversed() { try fm.moveItem(at: b, to: a) }
            return (.moved(pairs.reversed().map { ($0.1, $0.0) }), [])
        case .renamedBatch(let pairs):
            try BatchRename.undo(pairs)   // 整批一次改回（两步改名，互换名称也安全）
            return (.renamedBatch(pairs.map { ($0.1, $0.0) }), [])
        case .trashed(let pairs):
            for (a, b) in pairs { try fm.moveItem(at: b, to: a) }
            return (.created(pairs.map { $0.0 }), [])
        case .group(let ops):
            var inv: [UndoOp] = [], out: [URL] = []
            for sub in ops.reversed() {
                let r = try undoWithInverse(sub)
                inv.append(r.inverse)
                out += r.trashed
            }
            return (.group(inv.reversed()), out)
        case .created(let urls):
            var pairs: [(URL, URL)] = [], out: [URL] = []
            for u in urls {
                var r: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &r)
                if let r = r as URL? { pairs.append((u, r)); out.append(r) }
            }
            return (.trashed(pairs), out)
        }
    }
    /// Returns the Trash locations of anything the undo moved to the Trash.
    @discardableResult static func undo(_ op: UndoOp) throws -> [URL] {
        try undoWithInverse(op).trashed
    }
    static func readTags(_ u: URL) -> [String] {
        let fresh = URL(fileURLWithPath: u.path)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }
    static func setTags(_ u: URL, _ tags: [String]) throws {
        try (URL(fileURLWithPath: u.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
    static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw FBError("没有选中项目。") }
        let dir = first.deletingLastPathComponent().standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == dir.path }) else { throw FBError("只能压缩同一个文件夹里的项目。") }
        let p = Process(), errPipe = Pipe()
        let out: URL
        if urls.count == 1 {
            out = uniqueURL(in: dir, name: first.lastPathComponent + ".zip", copy: false)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path]
        } else {
            out = uniqueURL(in: dir, name: "归档.zip", copy: false)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            // 文件名前加「./」：以「-」开头的文件名不会被 zip 当成命令行选项（zip 存档时会去掉「./」）
            p.arguments = ["-r", "-y", "-q", out.path] + urls.map { "./" + $0.lastPathComponent }
        }
        p.standardError = errPipe; p.standardOutput = FileHandle.nullDevice
        try p.run()
        // 先读完错误输出再等进程结束：输出超过管道缓冲区（约 64 KB）时，先等会互相卡死
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: out)   // 不留半截压缩包
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw FBError("压缩失败（\(p.terminationStatus)）：\(msg)")
        }
        return out
    }
}

extension URL {
    /// 真实路径（/tmp → /private/tmp），和目录枚举得到的 URL 一致
    var realFileURL: URL {
        guard isFileURL, let r = realpath(path, nil) else { return standardizedFileURL }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r))
    }
}
func samePath(_ a: URL?, _ b: URL?) -> Bool { guard let a = a, let b = b else { return false }; return a.standardizedFileURL.path == b.standardizedFileURL.path }

/// 选中项里有和列表写法不同的 URL（/tmp 与 /private/tmp 等同一位置的两种写法）时，按名称在当前文件夹里对上，返回「选中项 → 列表里的 URL」。
/// 只在有对不上的选中项时才调用：每个不同的上级文件夹做一次 realpath，按名称查一次表。
func matchByName(_ unmatched: [URL], dir: URL, display: [FileItem]) -> [URL: URL] {
    guard !unmatched.isEmpty else { return [:] }
    let d = dir.realFileURL.path
    var parentOK: [String: Bool] = [:], byName: [String: URL]?, out: [URL: URL] = [:]
    for u in unmatched {
        let parent = u.deletingLastPathComponent()
        let ok: Bool
        if let c = parentOK[parent.path] { ok = c } else { ok = parent.realFileURL.path == d; parentOK[parent.path] = ok }
        guard ok else { continue }
        if byName == nil { byName = Dictionary(display.map { ($0.name, $0.url) }, uniquingKeysWith: { a, _ in a }) }
        if let v = byName?[u.lastPathComponent] { out[u] = v }
    }
    return out
}

/// 去掉祖先文件夹也在列表里的项目（文件夹搬走时里面的东西随之搬走）。
/// 在主线程上处理几千个项目也要快：只做字符串运算，同一个上级文件夹只往上查一次。
func withoutNested(_ urls: [URL]) -> [URL] {
    guard urls.count > 1 else { return urls }
    let paths = urls.map { $0.path }   // 列表里的网址已经规范化过；不再逐个规范化（2003 项时从约 60ms 降到约 6ms）
    let set = Set(paths)
    var memo: [String: Bool] = [:]
    func covered(_ d: String) -> Bool {
        if let m = memo[d] { return m }
        let r = set.contains(d) || (d != "/" && !d.isEmpty && covered((d as NSString).deletingLastPathComponent))
        memo[d] = r; return r
    }
    var out: [URL] = []; out.reserveCapacity(urls.count)
    for (u, p) in zip(urls, paths) where !covered((p as NSString).deletingLastPathComponent) { out.append(u) }
    return out
}

/// 把 /tmp 和 /private/tmp、/var 和 /private/var 这类系统固定软链接快速规整成同一路径；
/// 优先走纯字符串处理（避免在 FSEvents 高频回调里逐条调磁盘 fileExists / resolvingSymlinksInPath）。
func resolvedFilePath(_ p: String) -> String {
    var s = (p as NSString).standardizingPath
    if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    if s == "/tmp" || s.hasPrefix("/tmp/") { return "/private" + s }
    if s == "/var" || s.hasPrefix("/var/") { return "/private" + s }
    return s
}

/// 目录监视只关心当前文件夹和分栏视图里打开的各栏：子文件夹深处的改动不触发重读（大目录更省）。
func folderWatchIsRelevant(eventPath: String, flags: FSEventStreamEventFlags, roots: [String]) -> Bool {
    return folderWatchIsRelevant(eventPath: eventPath, flags: flags, resolvedRoots: Set(roots.map(resolvedFilePath)))
}

func folderWatchIsRelevant(eventPath: String, flags: FSEventStreamEventFlags, resolvedRoots rset: Set<String>) -> Bool {
    let special = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs |
        kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped |
        kFSEventStreamEventFlagRootChanged |
        kFSEventStreamEventFlagMount |
        kFSEventStreamEventFlagUnmount)
    if flags & special != 0 { return true }
    let ev = resolvedFilePath(eventPath)
    if rset.contains(ev) { return true }
    let parent = (ev as NSString).deletingLastPathComponent
    return rset.contains(parent)
}

/// 用 FSEvents 的文件级事件监视目录。DispatchSource 只盯目录本身的 vnode，
/// 原地改文件内容（AI 工具 / 编辑器常用的写法）不会通知，分栏视图里更深一层的改动也不会通知。
final class FolderWatcher {
    var roots: () -> [String] = { [] }
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var watched = ""

    func start(path: String) {
        let norm = resolvedFilePath(path)
        if watched == norm, stream != nil { return }
        stop()
        watched = norm
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil,
            { _, info, num, eventPaths, eventFlags, _ in
                guard let info = info else { return }
                let w = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                let rset = Set(w.roots().map(resolvedFilePath))
                guard !rset.isEmpty else { return }
                var relevant = false
                for i in 0..<Int(num) {
                    let p = i < paths.count ? paths[i] : ""
                    if folderWatchIsRelevant(eventPath: p, flags: eventFlags[i], resolvedRoots: rset) {
                        relevant = true; break
                    }
                }
                if relevant { w.onChange?() }
            },
            &ctx,
            [norm] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { watched = ""; return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        watched = ""
    }

    deinit { stop() }
}
