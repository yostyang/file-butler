import SwiftUI
import AppKit

let accentA = Color(red: 0.42, green: 0.36, blue: 0.98), accentB = Color(red: 0.18, green: 0.70, blue: 0.96)
let accentGrad = LinearGradient(colors: [accentA, accentB], startPoint: .topLeading, endPoint: .bottomTrailing)
let fdaURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

struct FileItem: Hashable {
    let url: URL; let name: String; let isDir: Bool; let isPackage: Bool
    let size: Int64; let modified: Date?; let created: Date?; let kind: String; let hidden: Bool
    var isFolderLike: Bool { isDir && !isPackage }
}
enum SortKey: String { case name, size, date, kind }
enum TransferMode { case auto, copy, move }

let listKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]

func makeItem(_ u: URL) -> FileItem {
    let v = try? u.resourceValues(forKeys: Set(listKeys))
    return FileItem(url: u, name: u.lastPathComponent, isDir: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false,
                    size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, created: v?.creationDate,
                    kind: v?.localizedTypeDescription ?? "", hidden: v?.isHidden ?? u.lastPathComponent.hasPrefix("."))
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
func uniqueCopyURL(in dir: URL, name: String) -> URL {
    let fm = FileManager.default
    var u = dir.appendingPathComponent(name)
    if !fm.fileExists(atPath: u.path) { return u }
    let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    var i = 1
    while true {
        let b = i == 1 ? "\(base) 副本" : "\(base) 副本 \(i)"
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

// MARK: - Tab
final class TabModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var path: URL
    @Published var items: [FileItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var permissionDenied = false
    @Published var selection: Set<URL> = []
    @Published var version = 0
    var back: [URL] = [], fwd: [URL] = []
    var sortKey: SortKey = .name, asc = true
    var raw: [FileItem] = []
    weak var app: AppState?
    private var loadToken = 0, pending = false
    private var watcher: DispatchSourceFileSystemObject?, watchedPath = ""

    var title: String { path.path == "/" ? "/" : FileManager.default.displayName(atPath: path.path) }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var selectedURLs: [URL] { selectedItems.map { $0.url } }

    init(path: URL, app: AppState) {
        self.path = path.standardizedFileURL; self.app = app
        if let k = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") { sortKey = k }
        if UserDefaults.standard.object(forKey: "sortAsc") != nil { asc = UserDefaults.standard.bool(forKey: "sortAsc") }
        reload()
    }
    deinit { watcher?.cancel() }

    func navigate(_ url: URL, record: Bool = true) {
        let u = url.standardizedFileURL
        guard u.path != path.path else { reload(); return }
        if record { back.append(path); fwd.removeAll() }
        path = u; selection = []; error = nil; permissionDenied = false
        reload(); app?.visited(u)
    }
    func goBack() { guard let p = back.popLast() else { NSSound.beep(); return }; fwd.append(path); path = p; selection = []; reload(); app?.visited(p) }
    func goForward() { guard let p = fwd.popLast() else { NSSound.beep(); return }; back.append(path); path = p; selection = []; reload(); app?.visited(p) }
    func goUp() {
        let p = path.deletingLastPathComponent()
        guard p.path != path.path else { NSSound.beep(); return }
        let old = path; navigate(p); selection = [old]
    }
    func resort() {
        items = sortItems(raw, key: sortKey, asc: asc); version += 1
        UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey"); UserDefaults.standard.set(asc, forKey: "sortAsc")
    }
    func reload() {
        loadToken += 1; let tok = loadToken, p = path, hidden = app?.showHidden ?? false
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var res: [FileItem] = []; var err: String?; var denied = false
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: p, includingPropertiesForKeys: listKeys, options: hidden ? [] : [.skipsHiddenFiles])
                res = urls.map(makeItem)
            } catch { err = error.localizedDescription; denied = isPermissionError(error) }
            DispatchQueue.main.async {
                guard tok == self.loadToken else { return }
                self.raw = res; self.error = err; self.permissionDenied = denied
                self.items = sortItems(res, key: self.sortKey, asc: self.asc)
                let all = Set(res.map { $0.url.standardizedFileURL })
                self.selection = Set(self.selection.filter { all.contains($0.standardizedFileURL) })
                self.loading = false; self.version += 1
                self.watch()
            }
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
}

final class PaneModel: ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var current = 0
    var tab: TabModel { tabs[max(0, min(current, tabs.count - 1))] }
}

struct AlertInfo: Identifiable { let id = UUID(); let title: String; let message: String; var fda = false }
struct RenameReq: Identifiable { let id = UUID(); let url: URL }
struct SizeReq: Identifiable { let id = UUID(); let url: URL }
struct VolumeInfo: Identifiable { var id: URL { url }; let url: URL; let name: String; let free: Int64; let total: Int64 }
enum UndoOp { case rename(URL, URL), moved([(URL, URL)]), trashed([(URL, URL)]), created([URL]) }
final class WeakTable { weak var t: FBTableView? }

// MARK: - App state
final class AppState: ObservableObject {
    @Published var panes: [PaneModel] = []
    @Published var active = 0
    @Published var dual: Bool = UserDefaults.standard.object(forKey: "dual") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dual, forKey: "dual"); if !dual { active = 0; focusActiveTable() } } }
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden"); reloadAll() } }
    @Published var showInfo = UserDefaults.standard.bool(forKey: "showInfo") {
        didSet { UserDefaults.standard.set(showInfo, forKey: "showInfo") } }
    @Published var bookmarks: [URL] = []
    @Published var recents: [URL] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var alert: AlertInfo?
    @Published var renameReq: RenameReq?
    @Published var sizeReq: SizeReq?
    @Published var editingPane: Int?
    @Published var busyText: String?
    let tables = [WeakTable(), WeakTable()]
    var undoStack: [UndoOp] = []
    var cutChangeCount = -1
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
            let paths = (ud.stringArray(forKey: "pane\(i)Tabs") ?? []).filter { fm.fileExists(atPath: $0) }
            let urls = paths.isEmpty ? [i == 0 ? home : home.appendingPathComponent("Downloads")] : paths.map { URL(fileURLWithPath: $0) }
            let p = PaneModel()
            p.tabs = urls.map { TabModel(path: $0, app: self) }
            p.current = min(ud.integer(forKey: "pane\(i)Cur"), p.tabs.count - 1)
            ps.append(p)
        }
        panes = ps
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshVolumes() }
        }
    }

    var activeTab: TabModel { panes[active].tab }
    var otherTab: TabModel { panes[1 - active].tab }
    var activeCoordinator: FileTable.Coordinator? { tables[active].t?.coord }

    func touch() { objectWillChange.send(); saveState() }
    func saveState() {
        for (i, p) in panes.enumerated() {
            ud.set(p.tabs.map { $0.path.path }, forKey: "pane\(i)Tabs"); ud.set(p.current, forKey: "pane\(i)Cur")
        }
    }
    func visited(_ u: URL) {
        recents.removeAll { $0.path == u.path }; recents.insert(u, at: 0)
        if recents.count > 15 { recents.removeLast(recents.count - 15) }
        ud.set(recents.map { $0.path }, forKey: "recents"); touch()
    }
    func go(_ u: URL) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { showError("找不到路径", u.path); return }
        if isDir.boolValue { activeTab.navigate(u) } else { activeTab.navigate(u.deletingLastPathComponent()); activeTab.selection = [u.standardizedFileURL] }
        focusActiveTable()
    }
    func newTab() {
        let p = panes[active]; let t = TabModel(path: p.tab.path, app: self)
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
    func focusActiveTable() {
        DispatchQueue.main.async { if let t = self.tables[self.active].t { t.window?.makeFirstResponder(t) } }
    }
    func reloadAll() { panes.forEach { $0.tabs.forEach { $0.reload() } } }
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
    func copyToClipboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects(urls.map { $0 as NSURL })
        cutChangeCount = cut ? pb.changeCount : -1
    }
    func paste(into dir: URL? = nil) {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { NSSound.beep(); return }
        let cut = pb.changeCount == cutChangeCount
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
        guard let first = urls.first else { NSSound.beep(); return }
        transfer(urls, to: first.deletingLastPathComponent(), mode: .copy)
    }
    func transfer(_ urls: [URL], to dir: URL, mode: TransferMode) {
        let dir = dir.standardizedFileURL
        guard !urls.isEmpty else { return }
        busyText = (mode == .move ? "正在移动 " : "正在拷贝 ") + "\(urls.count) 项…"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var moved: [(URL, URL)] = [], copied: [URL] = [], errs: [String] = []
            for raw in urls {
                let src = raw.standardizedFileURL, name = src.lastPathComponent
                let move = mode == .move || (mode == .auto && sameVolume(src, dir))
                if dir.path == src.path || dir.path.hasPrefix(src.path + "/") { errs.append("不能把「\(name)」放进它自身或它的子文件夹。"); continue }
                if move && src.deletingLastPathComponent().path == dir.path { continue }
                do {
                    if move {
                        let dst = dir.appendingPathComponent(name)
                        if fm.fileExists(atPath: dst.path) { errs.append("「\(name)」在目标文件夹中已存在，未移动。"); continue }
                        try fm.moveItem(at: src, to: dst); moved.append((src, dst))
                    } else {
                        let dst = uniqueCopyURL(in: dir, name: name)
                        try fm.copyItem(at: src, to: dst); copied.append(dst)
                    }
                } catch { errs.append("「\(name)」：\(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.busyText = nil
                if !moved.isEmpty { self.undoStack.append(.moved(moved)) }
                if !copied.isEmpty { self.undoStack.append(.created(copied)) }
                let landed = Set(moved.map { $0.1 } + copied)
                for p in self.panes { for t in p.tabs where t.path.path == dir.path { t.selection = landed } }
                self.reloadAll()
                if !errs.isEmpty { self.showError("部分操作未完成", errs.joined(separator: "\n")) }
            }
        }
    }
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        var done: [(URL, URL)] = [], errs: [String] = [], perm = false
        for u in urls {
            do {
                var out: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &out)
                if let o = out as URL? { done.append((u, o)) }
            } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)"); perm = perm || isPermissionError(error) }
        }
        if !done.isEmpty { undoStack.append(.trashed(done)) }
        reloadAll()
        if !errs.isEmpty { showError("无法移到废纸篓", errs.joined(separator: "\n"), fda: perm) }
    }
    func newFolder() {
        let dir = activeTab.path; var name = "未命名文件夹", i = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "未命名文件夹 \(i)"; i += 1 }
        let u = dir.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: u, withIntermediateDirectories: false)
            undoStack.append(.created([u])); activeTab.selection = [u.standardizedFileURL]; activeTab.reload()
            renameReq = RenameReq(url: u)
        } catch { showError("无法新建文件夹", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func rename(_ u: URL, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != u.lastPathComponent else { return }
        if n.contains("/") || n.contains(":") { showError("名称无效", "名称不能包含“/”或“:”。"); return }
        let dst = u.deletingLastPathComponent().appendingPathComponent(n)
        if fm.fileExists(atPath: dst.path) && dst.path.lowercased() != u.path.lowercased() { showError("无法重命名", "已经存在名为「\(n)」的项目。"); return }
        do {
            try fm.moveItem(at: u, to: dst); undoStack.append(.rename(u, dst))
            for p in panes { for t in p.tabs where t.path.path == u.deletingLastPathComponent().standardizedFileURL.path { t.selection = [dst.standardizedFileURL] } }
            reloadAll()
        } catch { showError("无法重命名", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func undo() {
        guard let op = undoStack.popLast() else { NSSound.beep(); return }
        do {
            switch op {
            case .rename(let a, let b): try fm.moveItem(at: b, to: a)
            case .moved(let pairs): for (a, b) in pairs.reversed() { try fm.moveItem(at: b, to: a) }
            case .trashed(let pairs): for (a, b) in pairs { try fm.moveItem(at: b, to: a) }
            case .created(let urls): for u in urls { try fm.trashItem(at: u, resultingItemURL: nil) }
            }
        } catch { showError("无法撤销", error.localizedDescription) }
        reloadAll()
    }
    func open(_ it: FileItem, in tab: TabModel) {
        if it.isFolderLike { tab.navigate(it.url) } else { NSWorkspace.shared.open(it.url) }
    }
}
