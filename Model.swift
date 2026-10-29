import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
enum SearchScope: String, CaseIterable { case folder, subfolders, mac
    var title: String { switch self { case .folder: return "当前文件夹"; case .subfolders: return "包括子文件夹"; case .mac: return "整台 Mac" } } }

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
    a.sorted { x, y in
        let byName = x.name.localizedStandardCompare(y.name) == .orderedAscending
        let r: Bool
        switch key {
        case .name: r = byName
        case .size: r = x.size == y.size ? byName : x.size < y.size
        case .date: r = (x.modified ?? .distantPast) < (y.modified ?? .distantPast)
        case .kind: r = x.kind == y.kind ? byName : x.kind.localizedStandardCompare(y.kind) == .orderedAscending
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
    func label(_ it: FileItem) -> (String, Int) {
        switch k {
        case .none: return ("", 0)
        case .name:
            let c = it.name.first.map { String($0).uppercased() } ?? "#"
            return (c.rangeOfCharacter(from: .letters) != nil ? c : "#", 0)
        case .kind: return (it.isFolderLike ? "文件夹" : (it.kind.isEmpty ? "其他" : it.kind), it.isFolderLike ? 0 : 1)
        case .date:
            guard let d = it.modified else { return ("未知", 9) }
            if cal.isDateInToday(d) { return ("今天", 0) }
            if cal.isDateInYesterday(d) { return ("昨天", 1) }
            let days = now.timeIntervalSince(d) / 86400
            if days < 7 { return ("过去 7 天", 2) }
            if days < 30 { return ("过去 30 天", 3) }
            if cal.component(.year, from: d) == cal.component(.year, from: now) { return ("今年早些时候", 4) }
            return ("\(cal.component(.year, from: d)) 年", 10000 - cal.component(.year, from: d))
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
func uniqueURL(in dir: URL, name: String, copy: Bool) -> URL {
    let fm = FileManager.default
    var u = dir.appendingPathComponent(name)
    if !fm.fileExists(atPath: u.path) { return u }
    var ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    if name.hasSuffix(".zip") && !copy { ext = "zip"; base = String(name.dropLast(4)) }
    var i = copy ? 1 : 2
    while true {
        let b = copy ? (i == 1 ? "\(base) 副本" : "\(base) 副本 \(i)") : "\(base) \(i)"
        u = dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)")
        if !fm.fileExists(atPath: u.path) { return u }
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
indirect enum UndoOp { case rename(URL, URL), moved([(URL, URL)]), trashed([(URL, URL)]), created([URL]), group([UndoOp]) }

// MARK: - Pure file operations (also used by --selftest)
enum FileOps {
    static let fm = FileManager.default
    static func trash(_ urls: [URL], progress: OpProgress? = nil) -> (done: [(URL, URL)], errs: [String], perm: Bool) {
        var done: [(URL, URL)] = [], errs: [String] = [], perm = false
        progress?.total = urls.count
        for u in urls {
            if progress?.isCancelled == true { break }
            defer { progress?.step() }
            do {
                var out: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &out)
                if let o = out as URL? { done.append((u, o)) }
            } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)"); perm = perm || isPermissionError(error) }
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
        if fm.fileExists(atPath: dst.path) && dst.path.lowercased() != u.path.lowercased() { throw FBError("已经存在名为「\(n)」的项目。") }
        try fm.moveItem(at: u, to: dst)
        return dst
    }
    /// Returns the Trash locations of anything the undo moved to the Trash.
    @discardableResult static func undo(_ op: UndoOp) throws -> [URL] {
        switch op {
        case .rename(let a, let b): try fm.moveItem(at: b, to: a)
        case .moved(let pairs): for (a, b) in pairs.reversed() { try fm.moveItem(at: b, to: a) }
        case .trashed(let pairs): for (a, b) in pairs { try fm.moveItem(at: b, to: a) }
        case .group(let ops):
            var out: [URL] = []
            for op in ops.reversed() { out += try undo(op) }
            return out
        case .created(let urls):
            var out: [URL] = []
            for u in urls { var r: NSURL?; try fm.trashItem(at: u, resultingItemURL: &r); if let r = r as URL? { out.append(r) } }
            return out
        }
        return []
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
            p.arguments = ["-r", "-y", "-q", out.path] + urls.map { $0.lastPathComponent }
        }
        p.standardError = errPipe; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FBError("压缩失败（\(p.terminationStatus)）：\(msg)")
        }
        return out
    }
}

// MARK: - Tab
final class TabModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var path: URL
    @Published var items: [FileItem] = []
    @Published var display: [FileItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var permissionDenied = false
    @Published var selection: Set<URL> = [] { didSet { if selection != oldValue { app?.selectionDidChange(self) } } }
    @Published var version = 0
    @Published var viewMode: ViewMode { didSet { app?.saveState() } }
    @Published var groupKey: GroupKey = .none { didSet { recompute() } }
    @Published var searchText = ""
    @Published var searchScope: SearchScope = .folder { didSet { if searchScope != oldValue { refreshSearch() } } }
    @Published var tagFilter: String?
    @Published var searchResults: [FileItem] = []
    @Published var searching = false
    @Published var columnChain: [URL] = []
    var back: [URL] = [], fwd: [URL] = []
    var sortKey: SortKey = .name, asc = true
    var anchor: URL?
    var freeBytes: Int64?
    private var cacheVersion = -1
    private var groupsCache: [(String, [FileItem])] = []
    private var orderCache: [URL] = []
    private var indexCache: [URL: Int] = [:]
    private func fillCaches() {
        guard cacheVersion != version else { return }
        cacheVersion = version
        groupsCache = groupItems(display, by: groupKey)
        orderCache = groupsCache.flatMap { $0.1 }.map { $0.url }
        indexCache = Dictionary(display.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }
    /// 分组结果按 version 缓存，选择变化时不再重新分组
    var groups: [(String, [FileItem])] { fillCaches(); return groupsCache }
    var groupedOrder: [URL] { fillCaches(); return orderCache }
    weak var app: AppState?
    private var loadToken = 0, pending = false, searchToken = 0
    private var watcher: DispatchSourceFileSystemObject?, watchedPath = ""
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    var title: String {
        if let t = tagFilter { return "标签：\(t)" }
        let p = viewMode == .column ? (columnChain.last ?? path) : path
        return p.path == "/" ? "/" : FileManager.default.displayName(atPath: p.path)
    }
    /// 路径栏显示的目标（访达行为）：分栏视图里是最深的选中项；其他视图是当前文件夹 + 单个选中项。
    var pathTarget: URL {
        if tagFilter == nil, selection.count == 1, let s = selection.first { return s }
        if viewMode == .column, let c = columnChain.last { return c }
        return path
    }
    var isGlobalSearch: Bool { tagFilter != nil || (!searchText.isEmpty && searchScope != .folder) }
    var searchActive: Bool { tagFilter != nil || !searchText.isEmpty }
    var selectedItems: [FileItem] {
        guard !selection.isEmpty else { return [] }
        fillCaches()
        var inDisplay: [(Int, FileItem)] = [], rest: [URL] = []
        for u in selection { if let i = indexCache[u] { inDisplay.append((i, display[i])) } else { rest.append(u) } }
        return inDisplay.sorted { $0.0 < $1.0 }.map { $0.1 } + rest.sorted { $0.path < $1.path }.filter { FileManager.default.fileExists(atPath: $0.path) }.map(makeItem)
    }
    /// 状态栏用的选中摘要：只查已加载的列表，不逐个读取磁盘（大量选中时也不卡）
    var selectionSummary: (count: Int, size: Int64, hasFolder: Bool) {
        guard !selection.isEmpty else { return (0, 0, false) }
        fillCaches()
        var size: Int64 = 0, folder = false
        for u in selection { if let i = indexCache[u] { let it = display[i]; if it.isFolderLike { folder = true } else { size += it.size } } }
        return (selection.count, size, folder)
    }
    var selectedURLs: [URL] {
        guard !selection.isEmpty else { return [] }
        fillCaches()
        var inDisplay: [(Int, URL)] = [], rest: [URL] = []
        for u in selection { if let i = indexCache[u] { inDisplay.append((i, u)) } else { rest.append(u) } }
        return inDisplay.sorted { $0.0 < $1.0 }.map { $0.1 } + rest.sorted { $0.path < $1.path }
    }

    init(path: URL, app: AppState, mode: ViewMode = .list) {
        self.path = path.standardizedFileURL; self.app = app; self.viewMode = mode
        if let k = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") { sortKey = k }
        if UserDefaults.standard.object(forKey: "sortAsc") != nil { asc = UserDefaults.standard.bool(forKey: "sortAsc") }
        reload()
    }
    deinit { watcher?.cancel(); query?.stop(); observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func navigate(_ url: URL, record: Bool = true) {
        let u = url.standardizedFileURL
        if searchActive { clearSearch() }
        guard u.path != path.path else { reload(); return }
        if record { back.append(path); fwd.removeAll() }
        path = u; selection = []; error = nil; permissionDenied = false; columnChain = []
        reload(); app?.visited(u)
    }
    func goBack() { guard let p = back.popLast() else { NSSound.beep(); return }; fwd.append(path); path = p; selection = []; columnChain = []; reload(); app?.visited(p) }
    func goForward() { guard let p = fwd.popLast() else { NSSound.beep(); return }; back.append(path); path = p; selection = []; columnChain = []; reload(); app?.visited(p) }
    func goUp() {
        let p = path.deletingLastPathComponent()
        guard p.path != path.path else { NSSound.beep(); return }
        let old = path; navigate(p); selection = [old]
    }
    func setSort(_ k: SortKey, asc a: Bool) { sortKey = k; asc = a; resort() }
    func resort() {
        items = sortItems(items, key: sortKey, asc: asc); recompute()
        UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey"); UserDefaults.standard.set(asc, forKey: "sortAsc")
    }
    func recompute() {
        if isGlobalSearch { display = sortItems(searchResults, key: sortKey, asc: asc) }
        else if !searchText.isEmpty { display = items.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        else { display = items }
        version += 1
    }
    /// Click selection with ⌘ / ⇧ modifiers, used by icon, column and gallery views.
    func click(_ u: URL, order: [URL]) {
        let f = NSEvent.modifierFlags
        if f.contains(.command) { if selection.contains(u) { selection.remove(u) } else { selection.insert(u) }; anchor = u }
        else if f.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: u) {
            selection = Set(order[min(i, j)...max(i, j)])
        } else { selection = [u]; anchor = u }
    }
    func reload() {
        loadToken += 1; let tok = loadToken, p = path, hidden = app?.showHidden ?? false
        loading = true
        let key = sortKey, ascending = asc
        DispatchQueue.global(qos: .userInitiated).async {
            let (res, err, denied) = loadDirectory(p, hidden: hidden)
            let sorted = sortItems(res, key: key, asc: ascending)   // 排序也在后台完成
            let free = freeSpace(p)
            DispatchQueue.main.async { perfMark("reload main \(p.lastPathComponent) \(res.count)") {
                guard tok == self.loadToken else { return }
                self.error = err; self.permissionDenied = denied; self.freeBytes = free
                self.items = key == self.sortKey && ascending == self.asc ? sorted : sortItems(res, key: self.sortKey, asc: self.asc)
                let all = Set(res.map { $0.url }), dirPath = p.path
                let keep = Set(self.selection.filter { all.contains($0) || $0.deletingLastPathComponent().path != dirPath })
                if keep != self.selection { self.selection = keep }
                self.loading = false
                self.recompute()
                self.app?.noteTags(res)
                self.watch()
            } }
        }
    }
    private func watch() {
        guard watchedPath != path.path else { return }
        watcher?.cancel(); watcher = nil; watchedPath = path.path
        let fd = open(path.path, O_EVTONLY); guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in self?.scheduleReload() }
        s.setCancelHandler { close(fd) }
        s.resume(); watcher = s
    }
    private func scheduleReload() {
        if pending { return }; pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.pending = false; self?.reload() }
    }

    // MARK: search
    func setSearch(_ t: String) {
        guard t != searchText else { return }
        searchText = t
        if !t.isEmpty { tagFilter = nil }
        refreshSearch()
    }
    func refreshSearch() {
        if !isGlobalSearch { stopQuery(); searchResults = []; searching = false; recompute(); return }
        searchToken += 1; let tok = searchToken
        searching = true; recompute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, tok == self.searchToken else { return }
            self.startQuery()
        }
    }
    func showTag(_ t: String) { searchText = ""; tagFilter = t; selection = []; refreshSearch() }
    func clearSearch() { searchText = ""; tagFilter = nil; stopQuery(); searchResults = []; searching = false; recompute() }
    private func stopQuery() {
        query?.stop(); query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    private func startQuery() {
        stopQuery()
        let q = NSMetadataQuery()
        if let t = tagFilter {
            q.predicate = NSPredicate(format: "kMDItemUserTags == %@", t)
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        } else {
            q.predicate = NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(searchText)*")
            q.searchScopes = searchScope == .mac ? [NSMetadataQueryLocalComputerScope] : [path]
        }
        let nc = NotificationCenter.default
        for n in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(nc.addObserver(forName: n, object: q, queue: .main) { [weak self] _ in self?.collect() })
        }
        query = q
        q.start()
    }
    private func collect() {
        guard let q = query else { return }
        q.disableUpdates()
        var urls: [URL] = []
        for i in 0..<min(q.resultCount, 2000) {
            if let it = q.result(at: i) as? NSMetadataItem, let p = it.value(forAttribute: NSMetadataItemPathKey) as? String { urls.append(URL(fileURLWithPath: p)) }
        }
        q.enableUpdates()
        let tok = searchToken
        DispatchQueue.global(qos: .userInitiated).async {
            let res = urls.map(makeItem)
            DispatchQueue.main.async {
                guard tok == self.searchToken, self.isGlobalSearch else { return }
                self.searchResults = res; self.searching = false; self.recompute()
            }
        }
    }
}

final class OpStatus: ObservableObject { @Published var text: String? }

final class PaneModel: ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var current = 0
    var tab: TabModel { tabs[max(0, min(current, tabs.count - 1))] }
}

struct AlertInfo: Identifiable { let id = UUID(); let title: String; let message: String; var fda = false }
struct RenameReq: Identifiable { let id = UUID(); let url: URL }
struct SizeReq: Identifiable { let id = UUID(); let url: URL }
struct VolumeInfo: Identifiable { var id: URL { url }; let url: URL; let name: String; let free: Int64; let total: Int64 }
final class WeakView { weak var v: NSView? }

// MARK: - App state
final class AppState: ObservableObject {
    @Published var panes: [PaneModel] = []
    @Published var active = 0
    @Published var dual: Bool = UserDefaults.standard.object(forKey: "dual") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dual, forKey: "dual"); if !dual { active = 0; focusActiveTable() } } }
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden"); reloadAll() } }
    @Published var showPreview = UserDefaults.standard.bool(forKey: "showInfo") {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showInfo") } }
    @Published var iconSize: Double = UserDefaults.standard.object(forKey: "iconSize") as? Double ?? 80 {
        didSet { UserDefaults.standard.set(iconSize, forKey: "iconSize") } }
    @Published var bookmarks: [URL] = []
    @Published var recents: [URL] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var customTags: [String] = UserDefaults.standard.stringArray(forKey: "customTags") ?? []
    @Published var alert: AlertInfo?
    @Published var renameReq: RenameReq?
    @Published var sizeReq: SizeReq?
    @Published var editingPane: Int?
    /// 进度文字单独放在一个对象里：只刷新状态栏，不让整个窗口每 150ms 重绘一次
    let status = OpStatus()
    var busyText: String? { get { status.text } set { if status.text != newValue { status.text = newValue } } }
    @Published var searchFocus = 0
    @Published var showFDA = false
    @Published var inlineRename: URL?
    @Published var tagPopoverTick = 0
    @Published var showViewOptions = false
    @Published var showPathBar = UserDefaults.standard.object(forKey: "showPathBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPathBar, forKey: "showPathBar") } }
    let responders = [WeakView(), WeakView()]
    var controllers: [PaneController] = []
    var undoStack: [UndoOp] = []
    var cutChangeCount = -1
    var ownClip: (Int, [URL])?
    let favorites: [URL]
    let ud = UserDefaults.standard, fm = FileManager.default

    init() {
        let fm = FileManager.default, ud = UserDefaults.standard
        let home = fm.homeDirectoryForCurrentUser
        var f = [home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads"), URL(fileURLWithPath: "/Applications")]
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { f.append(icloud) }
        favorites = f
        bookmarks = (ud.stringArray(forKey: "bookmarks") ?? []).map { URL(fileURLWithPath: $0) }
        recents = (ud.stringArray(forKey: "recents") ?? []).map { URL(fileURLWithPath: $0) }
        var ps: [PaneModel] = []
        for i in 0..<2 {
            let saved = ud.stringArray(forKey: "pane\(i)Tabs") ?? [], modes = ud.stringArray(forKey: "pane\(i)Modes") ?? []
            var pairs: [(URL, ViewMode)] = []
            for (j, s) in saved.enumerated() where fm.fileExists(atPath: s) {
                pairs.append((URL(fileURLWithPath: s), j < modes.count ? ViewMode(rawValue: modes[j]) ?? .list : .list))
            }
            if pairs.isEmpty { pairs = [(i == 0 ? home : home.appendingPathComponent("Downloads"), .list)] }
            let p = PaneModel()
            p.tabs = pairs.map { TabModel(path: $0.0, app: self, mode: $0.1) }
            p.current = min(ud.integer(forKey: "pane\(i)Cur"), p.tabs.count - 1)
            ps.append(p)
        }
        panes = ps
        controllers = [PaneController(app: self, pane: 0), PaneController(app: self, pane: 1)]
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshVolumes() }
        }
    }

    var activeTab: TabModel { panes[active].tab }
    var otherTab: TabModel { panes[1 - active].tab }
    var activeController: PaneController { controllers[active] }
    var allTags: [String] { standardTags.map { $0.0 } + customTags }

    func touch() { objectWillChange.send(); saveState() }
    func saveState() {
        guard panes.count == 2 else { return }
        for (i, p) in panes.enumerated() {
            ud.set(p.tabs.map { $0.path.path }, forKey: "pane\(i)Tabs")
            ud.set(p.tabs.map { $0.viewMode.rawValue }, forKey: "pane\(i)Modes")
            ud.set(p.current, forKey: "pane\(i)Cur")
        }
    }
    func visited(_ u: URL) {
        recents.removeAll { $0.path == u.path }; recents.insert(u, at: 0)
        if recents.count > 15 { recents.removeLast(recents.count - 15) }
        ud.set(recents.map { $0.path }, forKey: "recents"); touch()
    }
    func noteTags(_ items: [FileItem]) {
        let std = Set(standardTags.map { $0.0 }).union(englishTags.keys)
        let new = Set(items.flatMap { $0.tags }).subtracting(std).subtracting(customTags)
        guard !new.isEmpty else { return }
        customTags += new.sorted(); ud.set(customTags, forKey: "customTags")
    }
    func selectionDidChange(_ t: TabModel) {
        for (i, p) in panes.enumerated() where p.tab === t { if i < controllers.count { controllers[i].refreshQL() } }
    }
    func go(_ u: URL) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { showError("找不到路径", u.path); return }
        if isDir.boolValue { activeTab.navigate(u) } else { activeTab.navigate(u.deletingLastPathComponent()); activeTab.selection = [u.standardizedFileURL] }
        focusActiveTable()
    }
    func newTab() {
        let p = panes[active]; let t = TabModel(path: p.tab.path, app: self, mode: p.tab.viewMode)
        p.tabs.insert(t, at: p.current + 1); p.current += 1; touch(); focusActiveTable()
    }
    func closeTab(pane: Int? = nil, index: Int? = nil) {
        let p = panes[pane ?? active]; let i = index ?? p.current
        guard p.tabs.count > 1 else { NSSound.beep(); return }
        p.tabs.remove(at: i); p.current = min(p.current >= i && p.current > 0 ? p.current - 1 : p.current, p.tabs.count - 1)
        touch(); focusActiveTable()
    }
    func selectTab(pane: Int, index: Int) { panes[pane].current = index; active = pane; touch(); focusActiveTable() }
    func switchPane() { guard dual else { NSSound.beep(); return }; active = 1 - active; focusActiveTable() }
    func focusActiveTable() { focusPane(active) }
    func focusPane(_ i: Int) {
        if active != i { active = i }
        DispatchQueue.main.async { if let v = self.responders[i].v, v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) } }
    }
    func setViewMode(_ m: ViewMode) { activeTab.viewMode = m; if m == .list || m == .column { ThumbCache.purgeImages() }; objectWillChange.send(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.focusActiveTable() } }
    func reloadAll() { panes.forEach { $0.tabs.forEach { $0.reload() } } }
    /// 文件操作后只刷新正在显示的标签页；后台标签页由目录监视自动刷新
    func reloadVisible() { panes.forEach { $0.tab.reload() } }
    func addBookmark(_ u: URL? = nil) {
        let u = u ?? activeTab.path
        guard !bookmarks.contains(where: { $0.path == u.path }) else { return }
        bookmarks.append(u); ud.set(bookmarks.map { $0.path }, forKey: "bookmarks")
    }
    func removeBookmark(_ u: URL) { bookmarks.removeAll { $0.path == u.path }; ud.set(bookmarks.map { $0.path }, forKey: "bookmarks") }
    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return VolumeInfo(url: u, name: v?.volumeLocalizedName ?? u.lastPathComponent, free: v?.volumeAvailableCapacityForImportantUsage ?? 0, total: Int64(v?.volumeTotalCapacity ?? 0))
        }
    }
    func showError(_ title: String, _ msg: String, fda: Bool = false) { alert = AlertInfo(title: title, message: msg, fda: fda) }

    // MARK: file operations
    func openURLs(_ urls: [URL], in tab: TabModel) {
        let items = urls.map(makeItem)
        if let folder = items.first(where: { $0.isFolderLike }) { items.filter { !$0.isFolderLike }.forEach { NSWorkspace.shared.open($0.url) }; tab.navigate(folder.url) }
        else { items.forEach { NSWorkspace.shared.open($0.url) } }
    }
    func open(_ it: FileItem, in tab: TabModel) {
        if it.isFolderLike { tab.navigate(it.url) } else { NSWorkspace.shared.open(it.url) }
    }
    /// 写剪贴板放到后台（几千个 URL 写入要 100ms 以上）；写完之前粘贴直接用内存里的列表
    let clipQueue = DispatchQueue(label: "filebutler.clipboard", qos: .userInitiated)
    var clipPending: (Int, [URL], Bool)?
    var clipToken = 0
    func copyToClipboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        clipToken += 1; let tok = clipToken
        clipPending = (tok, urls, cut); ownClip = nil; cutChangeCount = -1
        clipQueue.async {
            let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects(urls.map { $0 as NSURL })
            let cc = pb.changeCount
            DispatchQueue.main.async {
                guard self.clipPending?.0 == tok else { return }
                self.clipPending = nil; self.ownClip = (cc, urls)
                self.cutChangeCount = cut ? cc : -1
            }
        }
    }
    func paste(into dir: URL? = nil, forceMove: Bool = false) {
        let pb = NSPasteboard.general
        // 自己拷贝的内容直接用内存里的列表（读取剪贴板里几千个 URL 很慢）
        var urls: [URL], cut: Bool
        if let p = clipPending { urls = p.1; cut = p.2 || forceMove; if p.2 { clipPending = (p.0, p.1, false) } }
        else {
            urls = ownClip?.0 == pb.changeCount ? ownClip!.1 : perfMark("paste read") { fileURLs(pb) }
            cut = pb.changeCount == cutChangeCount || forceMove
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        transfer(urls, to: dir ?? activeTab.path, mode: cut ? .move : .copy)
        if cut { cutChangeCount = -1 }
    }
    func copyToOther(move: Bool) {
        guard dual else { NSSound.beep(); return }
        let urls = activeTab.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        transfer(urls, to: otherTab.path, mode: move ? .move : .copy)
    }
    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        for (dir, group) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() }) { transfer(group, to: dir, mode: .copy) }
    }
    /// SwiftUI 视图（分栏、画廊、侧边栏、路径栏）的拖放入口
    func dropProviders(_ ps: [NSItemProvider], to dir: URL) -> Bool {
        let mods = DragMods.current
        let group = DispatchGroup(), lock = NSLock(); var urls: [URL] = []
        for p in ps where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in if let u = u, u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }; group.leave() }
        }
        group.notify(queue: .main) { if !urls.isEmpty { self.performDrop(urls, to: dir, mods: mods) } }
        return true
    }
    /// 所有拖放最终都走这里（列表、图标、分栏、画廊、侧边栏、路径栏、从访达拖进来）
    @discardableResult func performDrop(_ urls: [URL], to dir: URL, mods: NSEvent.ModifierFlags? = nil) -> Bool {
        let saved = DragMods.override
        if let m = mods { DragMods.override = m }
        let kind = planDrop(urls, to: dir)
        DragMods.override = saved
        switch kind {
        case .none: return false
        case .move: transfer(urls, to: dir, mode: .move)
        case .copy: transfer(urls, to: dir, mode: .copy)
        case .alias:
            var made: [URL] = [], errs: [String] = []
            for u in urls { do { made.append(try FileOps.makeAlias(u, in: dir)) } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)") } }
            if !made.isEmpty { undoStack.append(.created(made)) }
            reload(dirs: [dir])
            if !errs.isEmpty { showError("无法制作替身", errs.joined(separator: "\n")) }
        }
        return true
    }

    // MARK: 后台操作队列：所有耗时的文件操作都在这里串行执行，主线程只更新界面
    let opQueue = DispatchQueue(label: "filebutler.ops", qos: .userInitiated)
    var progress: OpProgress?
    private var progressTimer: Timer?
    /// 测试用：同名冲突时的固定选择（nil = 弹出访达样式的对话框）
    static var conflictOverride: (Conflict, Bool)?
    func beginOp(_ verb: String, count: Int) -> OpProgress {
        let p = OpProgress(); p.verb = verb; p.total = count; progress = p
        busyText = "正在\(verb) \(count) 项…"
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.progress else { return }
            let t = "正在\(p.verb) \(min(p.done + 1, p.total))/\(p.total) 项…"
            if self.busyText != t { self.busyText = t }
        }
        return p
    }
    func endOp(_ p: OpProgress) {
        if progress === p { progress = nil; progressTimer?.invalidate(); progressTimer = nil; busyText = nil }
    }
    func cancelOp() { progress?.cancel() }
    /// 访达样式的同名冲突对话框（在后台线程调用，同步等主线程的选择）
    func askConflict(_ name: String, move: Bool) -> (Conflict, Bool) {
        if let o = AppState.conflictOverride { return o }
        if TestEnv.active { return (.keepBoth, false) }   // 测试时绝不弹出对话框
        var out: (Conflict, Bool) = (.stop, false)
        DispatchQueue.main.sync {
            let a = NSAlert()
            a.messageText = "此位置已存在名称为“\(name)”的项目。"
            a.informativeText = "要用正在\(move ? "移动" : "拷贝")的项目替换它吗？"
            a.addButton(withTitle: "替换"); a.addButton(withTitle: "停止"); a.addButton(withTitle: "保留两者")
            a.showsSuppressionButton = true; a.suppressionButton?.title = "全部应用"
            let r = a.runModal()
            let all = a.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn: out = (.replace, all)
            case .alertThirdButtonReturn: out = (.keepBoth, all)
            default: out = (.stop, false)
            }
        }
        return out
    }
    /// 只刷新显示着这些文件夹的标签页
    func reload(dirs: [URL]) {
        let set = Set(dirs.map { $0.standardizedFileURL.realFileURL.path })
        for p in panes {
            let t = p.tab
            let cur = [t.path] + t.columnChain
            if t.isGlobalSearch || cur.contains(where: { set.contains($0.realFileURL.path) }) { t.reload() }
        }
    }
    /// 立即从界面上去掉已经移走的项目（不等目录重新读取），让操作的反馈是即时的
    func removeFromLists(_ urls: [URL]) {
        let gone = Set(urls.map { $0.standardizedFileURL })
        guard !gone.isEmpty else { return }
        for p in panes { for t in p.tabs where t.items.contains(where: { gone.contains($0.url) }) {
            t.items.removeAll { gone.contains($0.url) }
            let keep = t.selection.subtracting(gone)
            if keep.count != t.selection.count { t.selection = keep }
            t.recompute()
        } }
    }
    func transfer(_ urls: [URL], to dir: URL, mode: TransferMode) {
        guard !urls.isEmpty else { return }
        let p = beginOp(mode == .move ? "移动" : "拷贝", count: urls.count)
        let srcDirs = Array(Set(urls.map { $0.deletingLastPathComponent() }))
        opQueue.async {
            let r = FileOps.transfer(urls, to: dir, mode: mode, progress: p, resolve: { [weak self] n, mv in self?.askConflict(n, move: mv) ?? (.stop, false) })
            DispatchQueue.main.async { perfMark("transfer done") {
                self.endOp(p)
                var ops: [UndoOp] = []
                if !r.replaced.isEmpty { ops.append(.trashed(r.replaced)) }
                if !r.moved.isEmpty { ops.append(.moved(r.moved)) }
                if !r.copied.isEmpty { ops.append(.created(r.copied)) }
                if ops.count == 1 { self.undoStack.append(ops[0]) } else if !ops.isEmpty { self.undoStack.append(.group(ops)) }
                self.removeFromLists(r.moved.map { $0.0 })
                let landed = Set((r.moved.map { $0.1 } + r.copied).map { $0.standardizedFileURL })
                for p in self.panes { for t in p.tabs where t.path.path == dir.standardizedFileURL.path && !landed.isEmpty { t.selection = landed } }
                self.reload(dirs: [dir] + srcDirs)
                if !r.errs.isEmpty { self.showError("部分操作未完成", r.errs.joined(separator: "\n")) }
            } }
        }
    }
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let p = beginOp("移到废纸篓", count: urls.count)
        let dirs = Array(Set(urls.map { $0.deletingLastPathComponent() }))
        opQueue.async {
            let r = FileOps.trash(urls, progress: p)
            DispatchQueue.main.async { perfMark("trash done") {
                self.endOp(p)
                if !r.done.isEmpty { self.undoStack.append(.trashed(r.done)) }
                perfMark("trash remove") { self.removeFromLists(r.done.map { $0.0 }) }
                perfMark("trash reload") { self.reload(dirs: dirs) }
                if !r.errs.isEmpty { self.showError("无法移到废纸篓", r.errs.joined(separator: "\n"), fda: r.perm) }
            } }
        }
    }
    /// 访达行为：在当前显示的文件夹（分栏视图里是最右侧的文件夹）新建「未命名文件夹」，选中并直接进入就地重命名。
    func newFolder(in target: URL? = nil) {
        let tab = activeTab
        let dir = target ?? (tab.viewMode == .column && !tab.isGlobalSearch ? tab.columnChain.last : nil) ?? tab.path
        do {
            let u = try FileOps.newFolder(in: dir).realFileURL
            undoStack.append(.created([u]))
            if tab.searchActive { tab.clearSearch() }
            tab.selection = [u]; tab.anchor = u
            tab.reload()
            beginRename(u)
        } catch { showError("无法新建文件夹", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func newFolderWithItems(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let dir = urls[0].deletingLastPathComponent().realFileURL.path
        guard urls.allSatisfy({ $0.deletingLastPathComponent().realFileURL.path == dir }) else { showError("无法新建文件夹", "所选项目需要在同一个文件夹里。"); return }
        do {
            let r = try FileOps.newFolderWithItems(urls)
            undoStack.append(.group([.created([r.folder]), .moved(r.moved)]))
            let u = r.folder.realFileURL
            activeTab.selection = [u]; activeTab.anchor = u
            reloadVisible(); beginRename(u)
        } catch { showError("无法新建文件夹", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func makeAlias(_ urls: [URL]) {
        var made: [URL] = [], errs: [String] = []
        for u in urls { do { made.append(try FileOps.makeAlias(u)) } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)") } }
        if !made.isEmpty { undoStack.append(.created(made)); activeTab.selection = Set(made.map { $0.realFileURL }) }
        reloadVisible()
        if !errs.isEmpty { showError("无法制作替身", errs.joined(separator: "\n")) }
    }
    /// 就地重命名（画廊视图没有可编辑的名称，退回到重命名窗口）
    func beginRename(_ u: URL) {
        if activeTab.viewMode == .gallery && !activeTab.isGlobalSearch { renameReq = RenameReq(url: u) }
        else { inlineRename = u.realFileURL }
    }
    func rename(_ u: URL, to name: String) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != u.lastPathComponent else { return }
        do {
            let dst = try FileOps.rename(u, to: name); undoStack.append(.rename(u, dst))
            for p in panes { for t in p.tabs where t.selection.contains(where: { samePath($0, u) }) { t.selection = [dst.realFileURL]; t.anchor = dst.realFileURL } }
            reloadVisible()
        } catch { showError("无法重命名", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func zip(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        busyText = "正在压缩 \(urls.count) 项…"
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Result { try FileOps.zip(urls) }
            DispatchQueue.main.async {
                self.busyText = nil
                switch res {
                case .success(let out):
                    self.undoStack.append(.created([out]))
                    for p in self.panes { for t in p.tabs where t.path.path == out.deletingLastPathComponent().path { t.selection = [out.standardizedFileURL] } }
                    self.reloadVisible()
                case .failure(let e): self.showError("无法压缩", e.localizedDescription)
                }
            }
        }
    }
    func toggleTag(_ tag: String, _ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let allHave = urls.allSatisfy { FileOps.readTags($0).contains(tag) }
        var errs: [String] = []
        for u in urls {
            var t = FileOps.readTags(u)
            if allHave { t.removeAll { $0 == tag } } else if !t.contains(tag) { t.append(tag) }
            do { try FileOps.setTags(u, t) } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)") }
        }
        if tagColor(tag) == nil && !customTags.contains(tag) { customTags.append(tag); ud.set(customTags, forKey: "customTags") }
        reloadVisible()
        for p in panes { for t in p.tabs where t.isGlobalSearch { t.refreshSearch() } }
        if !errs.isEmpty { showError("无法修改标签", errs.joined(separator: "\n")) }
    }
    func undo() {
        guard let op = undoStack.popLast() else { NSSound.beep(); return }
        let p = beginOp("撤销", count: 1)
        opQueue.async {
            let err: String? = { do { try FileOps.undo(op); return nil } catch { return error.localizedDescription } }()
            DispatchQueue.main.async {
                self.endOp(p)
                if let e = err { self.showError("无法撤销", e) }
                self.reloadVisible()
            }
        }
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
