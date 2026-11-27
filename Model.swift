import SwiftUI
import AppKit

struct AlertInfo: Identifiable { let id = UUID(); let title: String; let message: String; var fda = false }
struct RenameReq: Identifiable { let id = UUID(); let url: URL }
struct SizeReq: Identifiable { let id = UUID(); let url: URL }
/// 只保留所在卷已装载的路径（纯字符串比较；/Volumes/<名称> 之外的路径都在启动磁盘上）
func recentsOnMountedVolumes(_ urls: [URL], mounted: [String]) -> [URL] {
    let roots = Set(mounted.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 })
    return urls.filter { u in
        let comps = u.path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2, comps[0] == "Volumes" else { return true }
        return roots.contains("/Volumes/" + comps[1])
    }
}
struct VolumeInfo: Identifiable { var id: URL { url }; let url: URL; let name: String; let free: Int64; let total: Int64 }
final class WeakView { weak var v: NSView? }

/// v0.7 置顶文件夹：固定在侧边栏顶部（高于「个人收藏」），支持自定义显示名与排序；外置盘未装载时自动隐藏但保留记录。
struct PinnedFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var alias: String?
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String {
        if let a = alias?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        return path == "/" ? rootVolumeName : cachedDisplayName(path)
    }
}

/// v0.7 保存布局：记录单/双栏状态、各栏所有标签页路径、显示方式、排序方式及当前激活标签页，一键打开。
struct TabSnapshot: Codable, Equatable {
    var path: String
    var viewMode: String
    var sortKey: String?
    var sortAsc: Bool?
}
struct PaneSnapshot: Codable, Equatable {
    var tabs: [TabSnapshot]
    var current: Int
}
struct WorkspaceLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var dual: Bool
    var activePane: Int
    var panes: [PaneSnapshot]
    private static func folderName(_ p: String) -> String {
        p == "/" ? rootVolumeName : (p as NSString).lastPathComponent
    }
    var summary: String {
        guard let p0 = panes.first, !p0.tabs.isEmpty else { return "" }
        let t0 = p0.tabs[max(0, min(p0.current, p0.tabs.count - 1))]
        let left = Self.folderName(t0.path) + (p0.tabs.count > 1 ? " 等\(p0.tabs.count)个" : "")
        guard dual, panes.count > 1, !panes[1].tabs.isEmpty else { return left }
        let p1 = panes[1]
        let t1 = p1.tabs[max(0, min(p1.current, p1.tabs.count - 1))]
        let right = Self.folderName(t1.path) + (p1.tabs.count > 1 ? " 等\(p1.tabs.count)个" : "")
        return "\(left) ⇄ \(right)"
    }
}

// MARK: - App state
final class AppState: ObservableObject {
    static let maxUndoDepth = 50
    @Published var panes: [PaneModel] = []
    @Published var active = 0
    @Published var dual: Bool = Settings.dual {
        didSet { Settings.dual = dual; if !dual { active = 0; focusActiveTable() } } }
    @Published var showHidden = Settings.showHidden {
        didSet { Settings.showHidden = showHidden; reloadAll() } }
    @Published var showPreview = Settings.showPreview {
        didSet { Settings.showPreview = showPreview } }
    @Published var iconSize: Double = Settings.iconSize {
        didSet { Settings.iconSize = iconSize } }
    @Published var pinnedFolders: [PinnedFolder] = []
    @Published var layouts: [WorkspaceLayout] = []
    @Published var bookmarks: [URL] = []
    @Published var recents: [URL] = []
    @Published var recentSearches: [String] = Settings.recentSearches
    @Published var savedSearches: [SavedSearch] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var customTags: [String] = Settings.customTags
    @Published var alert: AlertInfo?
    @Published var renameReq: RenameReq?
    @Published var sizeReq: SizeReq?
    @Published var editingPane: Int?
    /// v0.6：批量重命名窗口、命令面板、文件架
    /// 批量重命名：设为一个模型 = 以表单打开，设为 nil = 关闭（AppKit 表单，见 BatchRenamePanel；不是 @Published，打开 / 关闭不让整个窗口重绘）
    var batchRename: BatchRenameModel? = nil { didSet { if batchRename !== oldValue { showBatchRenamePanel() } } }
    private var renamePanel: BatchRenamePanel?
    let palette = PaletteModel()
    let shelf = ShelfModel()
    /// 最近一次批量重命名的结果（测试用）
    var lastBatchRename: [(URL, URL)] = []
    /// 进度文字单独放在一个对象里：只刷新状态栏，不让整个窗口每 150ms 重绘一次
    let status = OpStatus()
    var busyText: String? { get { status.text } set { if status.text != newValue { status.text = newValue } } }
    @Published var searchFocus = 0
    @Published var showFDA = false
    @Published var inlineRename: URL?
    @Published var tagPopoverTick = 0
    @Published var showViewOptions = false
    @Published var showPathBar = Settings.showPathBar {
        didSet { Settings.showPathBar = showPathBar } }
    let responders = [WeakView(), WeakView()]
    var controllers: [PaneController] = []
    var undoStack: [UndoOp] = []
    var redoStack: [UndoOp] = []
    var cutChangeCount = -1
    var ownClip: (Int, [URL])?
    let favorites: [URL]
    let fm = FileManager.default

    init() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var f = [home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads"), URL(fileURLWithPath: "/Applications")]
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { f.append(icloud) }
        favorites = f
        pinnedFolders = Settings.pinnedFolders
        layouts = Settings.savedLayouts
        bookmarks = Settings.bookmarks
        recents = Settings.recents
        savedSearches = Settings.savedSearches
        var ps: [PaneModel] = []
        for i in 0..<2 {
            let (saved, modes, cur) = Settings.loadPane(i)
            var pairs: [(URL, ViewMode)] = []
            for (j, s) in saved.enumerated() where fm.fileExists(atPath: s) {
                pairs.append((URL(fileURLWithPath: s), j < modes.count ? ViewMode(rawValue: modes[j]) ?? .list : .list))
            }
            if pairs.isEmpty { pairs = [(i == 0 ? home : home.appendingPathComponent("Downloads"), .list)] }
            let p = PaneModel()
            p.tabs = pairs.map { TabModel(path: $0.0, app: self, mode: $0.1) }
            p.current = min(cur, p.tabs.count - 1)
            ps.append(p)
        }
        panes = ps
        controllers = [PaneController(app: self, pane: 0), PaneController(app: self, pane: 1)]
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshVolumes() }
        }
        palette.app = self
    }

    var activeTab: TabModel { panes[active].tab }
    var otherTab: TabModel { panes[1 - active].tab }
    var activeController: PaneController { controllers[active] }
    var allTags: [String] { standardTags.map { $0.0 } + customTags }

    /// 记录一步可撤销操作：超过 maxUndoDepth 时淘汰最早的记录，并清空重做栈
    func recordUndo(_ op: UndoOp) {
        undoStack.append(op)
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst(undoStack.count - Self.maxUndoDepth) }
        redoStack.removeAll()
    }

    func touch() { objectWillChange.send(); saveState() }
    func saveState() {
        guard panes.count == 2 else { return }
        for (i, p) in panes.enumerated() {
            Settings.savePane(i, tabs: p.tabs, current: p.current)
        }
    }
    func visited(_ u: URL) {
        recents.removeAll { $0.path == u.path }; recents.insert(u, at: 0)
        if recents.count > 15 { recents.removeLast(recents.count - 15) }
        Settings.recents = recents; touch()
    }
    /// 侧边栏显示的「最近访问」：所在磁盘没有装载（外置盘拔掉了）的记录先不显示，记录本身保留，
    /// 磁盘再接上就会重新出现。只比较路径和已装载卷列表，不访问磁盘（不会唤醒休眠的硬盘、不弹窗）。
    var visibleRecents: [URL] { recentsOnMountedVolumes(recents, mounted: volumes.map { $0.url.path }) }
    func removeRecent(_ u: URL) {
        recents.removeAll { $0.path == u.path }
        Settings.recents = recents; touch()
    }
    func noteTags(_ items: [FileItem]) {
        let std = Set(standardTags.map { $0.0 }).union(englishTags.keys)
        let new = Set(items.flatMap { $0.tags }).subtracting(std).subtracting(customTags)
        guard !new.isEmpty else { return }
        customTags += new.sorted(); Settings.customTags = customTags
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
    /// 这一栏当前负责键盘的视图。切换显示方式时，旧视图的最后一次更新可能晚于新视图的创建，
    /// 登记的会是一个已经离开窗口的视图（于是活动栏不跟随鼠标、方向键发到另一栏）。
    /// 这时在窗口里找这一栏正在显示的视图并重新登记；只在登记的视图失效时才遍历视图树。
    var testWindow: NSWindow? {
        #if FB_TESTING
        return TestWindow.win
        #else
        return nil
        #endif
    }
    func keyView(_ i: Int, in w: NSWindow? = nil) -> NSView? {
        guard i < responders.count else { return nil }
        if let v = responders[i].v, v.window != nil, !v.isHiddenOrHasHiddenAncestor { return v }
        guard let root = (w ?? testWindow ?? NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.toolbar != nil }))?.contentView?.superview else { return responders[i].v }
        var found: NSView?
        func walk(_ v: NSView) {
            if found != nil || v.isHidden { return }
            if let k = v as? FBKeyView, k.pane == i { found = k; return }
            if let t = v as? FBTableView, (t.delegate as? FileTable.Coordinator)?.pane == i { found = t; return }
            if let c = v as? FBCollectionView, c.coord?.pane == i { found = c; return }
            v.subviews.forEach(walk)
        }
        walk(root)
        if let f = found { responders[i].v = f }
        return found ?? responders[i].v
    }
    func focusPane(_ i: Int) {
        if active != i { active = i }
        focusAttempt(i, 0)
    }
    /// 切换显示方式时新视图要下一轮才进窗口：没成功就稍后再试几次，避免焦点停在窗口上、快捷键无效
    private func focusAttempt(_ i: Int, _ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (n == 0 ? 0 : 0.05)) {
            guard self.active == i else { return }
            if let v = self.keyView(i), let w = v.window {
                if w.firstResponder === v || w.makeFirstResponder(v) { return }
            }
            if n < 10 { self.focusAttempt(i, n + 1) }
        }
    }
    func setViewMode(_ m: ViewMode) { activeTab.viewMode = m; if m == .list || m == .column { ThumbCache.purgeImages() }; objectWillChange.send(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.focusActiveTable() } }
    func reloadAll() { panes.forEach { $0.tabs.forEach { $0.reload() } } }
    /// 文件操作后只刷新正在显示的标签页；后台标签页由目录监视自动刷新
    func reloadVisible() { panes.forEach { $0.tab.reload() } }
    func addBookmark(_ u: URL? = nil) {
        let u = u ?? activeTab.path
        guard !bookmarks.contains(where: { $0.path == u.path }) else { return }
        bookmarks.append(u); Settings.bookmarks = bookmarks
    }
    func removeBookmark(_ u: URL) { bookmarks.removeAll { $0.path == u.path }; Settings.bookmarks = bookmarks }

    // MARK: v0.7 置顶文件夹（固定在侧边栏最上方；未装载外置盘上的置顶项先隐藏、盘接上后恢复，不读磁盘）
    var visiblePinnedFolders: [PinnedFolder] {
        let mounted = Set(recentsOnMountedVolumes(pinnedFolders.map { $0.url }, mounted: volumes.map { $0.url.path }).map { $0.path })
        return pinnedFolders.filter { mounted.contains($0.path) }
    }
    func isPinned(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.path
        return pinnedFolders.contains { $0.path == p }
    }
    func pinFolder(_ u: URL? = nil, alias: String? = nil) {
        let target = (u ?? (activeTab.viewMode == .column && !activeTab.isGlobalSearch ? activeTab.columnChain.last : nil) ?? activeTab.path).standardizedFileURL
        let cleanAlias = alias?.trimmingCharacters(in: .whitespaces)
        if let i = pinnedFolders.firstIndex(where: { $0.path == target.path }) {
            if let a = cleanAlias { pinnedFolders[i].alias = a.isEmpty ? nil : a }
        } else {
            pinnedFolders.append(PinnedFolder(path: target.path, alias: (cleanAlias?.isEmpty == false) ? cleanAlias : nil))
        }
        Settings.pinnedFolders = pinnedFolders
    }
    func unpinFolder(_ u: URL) {
        let p = u.standardizedFileURL.path
        pinnedFolders.removeAll { $0.path == p }
        Settings.pinnedFolders = pinnedFolders
    }
    func togglePin(_ u: URL? = nil) {
        let target = (u ?? (activeTab.viewMode == .column && !activeTab.isGlobalSearch ? activeTab.columnChain.last : nil) ?? activeTab.path).standardizedFileURL
        if isPinned(target) { unpinFolder(target) } else { pinFolder(target) }
    }
    func renamePinnedFolder(_ item: PinnedFolder, to alias: String) {
        guard let i = pinnedFolders.firstIndex(where: { $0.id == item.id }) else { return }
        let t = alias.trimmingCharacters(in: .whitespaces)
        pinnedFolders[i].alias = t.isEmpty ? nil : t
        Settings.pinnedFolders = pinnedFolders
    }
    func movePinnedFolder(_ item: PinnedFolder, by delta: Int) {
        guard let i = pinnedFolders.firstIndex(where: { $0.id == item.id }) else { return }
        let j = i + delta
        guard j >= 0 && j < pinnedFolders.count else { return }
        pinnedFolders.swapAt(i, j)
        Settings.pinnedFolders = pinnedFolders
    }
    func openInNewTab(_ u: URL, pane: Int? = nil) {
        let idx = pane ?? active
        let p = panes[idx]
        let t = TabModel(path: u, app: self, mode: p.tab.viewMode)
        p.tabs.insert(t, at: p.current + 1); p.current += 1; active = idx; touch(); focusActiveTable()
    }
    func openInOtherPane(_ u: URL) {
        if !dual { dual = true }
        let other = 1 - active
        panes[other].tab.navigate(u)
        active = other; touch(); focusActiveTable()
    }

    // MARK: v0.7 保存布局（两栏、各标签页路径、显示方式与排序一键保存和恢复）
    var defaultLayoutName: String {
        if dual, panes.count >= 2 { return "\(panes[0].tab.title) · \(panes[1].tab.title)" }
        return activeTab.title
    }
    private func snapshotPanes() -> [PaneSnapshot] {
        panes.map { p in
            PaneSnapshot(
                tabs: p.tabs.map { t in
                    let target = (t.viewMode == .column && !t.isGlobalSearch ? t.columnChain.last : nil) ?? t.path
                    return TabSnapshot(path: target.path, viewMode: t.viewMode.rawValue, sortKey: t.sortKey.rawValue, sortAsc: t.asc)
                },
                current: p.current
            )
        }
    }
    @discardableResult func saveCurrentLayout(name: String) -> WorkspaceLayout {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? defaultLayoutName : trimmed
        let snap = WorkspaceLayout(name: finalName, dual: dual, activePane: active, panes: snapshotPanes())
        if let i = layouts.firstIndex(where: { $0.name == finalName }) {
            var updated = snap; updated.id = layouts[i].id
            layouts[i] = updated
            Settings.savedLayouts = layouts
            return updated
        }
        layouts.append(snap)
        Settings.savedLayouts = layouts
        return snap
    }
    func promptSaveLayout() {
        if let n = promptText(title: "保存布局", message: "把当前单/双栏、各标签页路径和显示方式存为一个布局，以后点一下就能恢复。", initial: defaultLayoutName) {
            saveCurrentLayout(name: n)
        }
    }
    func updateLayout(_ l: WorkspaceLayout) {
        guard let i = layouts.firstIndex(where: { $0.id == l.id }) else { return }
        layouts[i].dual = dual
        layouts[i].activePane = active
        layouts[i].panes = snapshotPanes()
        Settings.savedLayouts = layouts
    }
    func renameLayout(_ l: WorkspaceLayout, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = layouts.firstIndex(where: { $0.id == l.id }) else { return }
        layouts[i].name = t
        Settings.savedLayouts = layouts
    }
    func removeLayout(_ l: WorkspaceLayout) {
        layouts.removeAll { $0.id == l.id }
        Settings.savedLayouts = layouts
    }
    func applyLayout(_ l: WorkspaceLayout) {
        var missing: [String] = []
        for i in 0..<min(2, l.panes.count) {
            let ps = l.panes[i]
            var newTabs: [TabModel] = []
            for ts in ps.tabs {
                if fm.fileExists(atPath: ts.path) {
                    let mode = ViewMode(rawValue: ts.viewMode) ?? .list
                    let tab = TabModel(path: URL(fileURLWithPath: ts.path), app: self, mode: mode)
                    if let sk = ts.sortKey.flatMap(SortKey.init(rawValue:)), let sa = ts.sortAsc, (sk != tab.sortKey || sa != tab.asc) {
                        tab.setSort(sk, asc: sa)
                    }
                    newTabs.append(tab)
                } else {
                    missing.append(ts.path)
                }
            }
            if !newTabs.isEmpty {
                panes[i].tabs = newTabs
                panes[i].current = min(max(0, ps.current), newTabs.count - 1)
            }
        }
        if dual != l.dual { dual = l.dual }
        active = l.dual ? min(max(0, l.activePane), 1) : 0
        touch()
        focusActiveTable()
        if !missing.isEmpty {
            showError("部分布局路径未打开", "以下文件夹不存在或所在磁盘未装载：\n" + missing.joined(separator: "\n"))
        }
    }
    // MARK: 最近搜索 / 已存搜索（仿访达：搜索建议、智能文件夹）
    func recordSearch(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recentSearches.removeAll { $0 == t }; recentSearches.insert(t, at: 0)
        if recentSearches.count > 10 { recentSearches.removeLast() }
        Settings.recentSearches = recentSearches
    }
    func clearRecentSearches() { recentSearches = []; Settings.recentSearches = [] }
    func saveCurrentSearch(name: String, tab: TabModel? = nil) {
        let t = tab ?? activeTab
        let s = SavedSearch(name: name.isEmpty ? (t.searchText.isEmpty ? "未命名搜索" : t.searchText) : name,
                            text: t.searchText, scope: t.searchScope, matchMode: t.matchMode, criteria: t.criteria)
        savedSearches.removeAll { $0.name == s.name }; savedSearches.append(s); persistSearches()
        recordSearch(t.searchText)
    }
    func removeSavedSearch(_ s: SavedSearch) { savedSearches.removeAll { $0.id == s.id }; persistSearches() }
    func renameSavedSearch(_ s: SavedSearch, to name: String) {
        guard let i = savedSearches.firstIndex(where: { $0.id == s.id }) else { return }
        savedSearches[i].name = name; persistSearches()
    }
    private func persistSearches() { Settings.savedSearches = savedSearches }
    func runSaved(_ s: SavedSearch) { activeTab.applySaved(s); focusActiveTable() }
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
            urls = ownClip?.0 == pb.changeCount ? ownClip!.1 : fileURLs(pb)
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
            if !made.isEmpty { recordUndo(.created(made)) }
            reload(dirs: [dir])
            if !errs.isEmpty { showError("无法制作替身", errs.joined(separator: "\n")) }
        }
        return true
    }

    // MARK: 后台操作队列：所有耗时的文件操作都在这里串行执行，主线程只更新界面
    let opQueue = DispatchQueue(label: "filebutler.ops", qos: .userInitiated)
    var progress: OpProgress?
    /// 最近一次后台文件操作（不含界面刷新）用时，测试报告用
    var lastOpMs: Double = 0
    /// 最近一次撤销放进废纸篓的项目（撤销拷贝时），测试清理用
    var lastUndoTrashed: [URL] = []
    private var opStart = Date()
    private var progressTimer: Timer?
    #if FB_TESTING
    /// 测试用：同名冲突时的固定选择（nil = 弹出访达样式的对话框）
    static var conflictOverride: (Conflict, Bool)?
    #endif
    /// 正在进行和排队的操作（进度窗口按这个列表显示，可以同时有多个）
    let center = OpCenter()
    func beginOp(_ verb: String, count: Int, kind: OpKind = .other, first: String = "", dest: String = "") -> OpProgress {
        let p = OpProgress(); p.verb = verb; p.total = count; p.kind = kind; p.firstName = first; p.destName = dest
        center.add(p)
        if progress == nil { progress = p; opStart = Date(); startStatusTimer() }
        return p
    }
    private func startStatusTimer() {
        busyText = progress.map { "正在\($0.verb) \($0.total) 项…" }
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.progress else { return }
            var t = "正在\(p.verb) \(min(p.done + 1, p.total))/\(p.total) 项…"
            let bt = p.bytesTotal
            if bt > 0 { t += " \(min(100, Int(Double(p.bytesDone) * 100 / Double(bt))))%" }
            if self.busyText != t { self.busyText = t }
        }
    }
    func endOp(_ p: OpProgress) {
        center.remove(p)
        guard progress === p else { return }
        lastOpMs = Date().timeIntervalSince(opStart) * 1000
        progressTimer?.invalidate(); progressTimer = nil
        // 还有排队的操作：状态栏接着显示它；否则清空
        if let next = center.ops.first { progress = next; opStart = Date(); startStatusTimer() } else { progress = nil; busyText = nil }
    }
    func cancelOp() { progress?.cancel() }
    func cancelAll() { for p in center.ops { p.cancel() } }
    /// 访达的同名冲突对话框（文字、按钮顺序与访达一致：保留两者 | 停止 | 替换；多个冲突时才有「应用到全部」）
    static func conflictAlert(name: String, move: Bool, multi: Bool) -> NSAlert {
        let a = NSAlert()
        a.messageText = "此位置已经存在名称为“\(name)”的项目。"
        a.informativeText = "你要使用正在\(move ? "移动" : "拷贝")的项目进行替换吗？"
        a.addButton(withTitle: "替换")                       // 最右、默认按钮
        a.addButton(withTitle: "停止").keyEquivalent = "\u{1b}"   // Esc = 停止
        a.addButton(withTitle: "保留两者")
        if multi { a.showsSuppressionButton = true; a.suppressionButton?.title = "应用到全部" }
        return a
    }
    /// 在后台线程调用，等主线程上的用户选择。
    /// 不用 DispatchQueue.main.sync + runModal：那样对话框开着的整段时间里主队列被这个 block 占住，
    /// 其他 DispatchQueue.main.async（目录刷新、缩略图、别的操作完成）全部排队；主线程一旦在等后台任务还会直接死锁。
    /// 改为通过 RunLoop.main.perform 投递：模态对话框的嵌套 run loop 里主队列照常执行，后台线程用信号量等待结果。
    func askConflict(_ name: String, move: Bool, multi: Bool = false) -> (Conflict, Bool) {
        #if FB_TESTING
        if let o = AppState.conflictOverride { return o }
        if TestEnv.active { return (.keepBoth, false) }   // 测试时绝不弹出对话框
        #endif
        func ask() -> (Conflict, Bool) {
            let a = AppState.conflictAlert(name: name, move: move, multi: multi)
            let r = a.runModal()
            let all = multi && a.suppressionButton?.state == .on
            switch r {
            case .alertFirstButtonReturn: return (.replace, all)
            case .alertThirdButtonReturn: return (.keepBoth, all)
            default: return (.stop, false)
            }
        }
        if Thread.isMainThread { return ask() }   // 防御：主线程上直接问，绝不在主线程等信号量
        var out: (Conflict, Bool) = (.stop, false)
        let sem = DispatchSemaphore(value: 0)
        RunLoop.main.perform(inModes: [.common]) { out = ask(); sem.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        sem.wait()
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
        // 来源 URL 本来就取自列表（已规范化），直接用；匹配不到时再规范化一遍
        var gone = Set(urls)
        guard !gone.isEmpty else { return }
        let tabs = panes.flatMap { $0.tabs }
        if !tabs.contains(where: { t in t.items.contains(where: { gone.contains($0.url) }) }) { gone = Set(urls.map { $0.standardizedFileURL }) }
        for t in tabs {
            let before = t.items.count
            t.items.removeAll { gone.contains($0.url) }
            if t.items.count == before { continue }
            let keep = t.selection.subtracting(gone)
            if keep.count != t.selection.count { t.selection = keep }
            t.recompute()
        }
    }
    func transfer(_ urls: [URL], to dir: URL, mode: TransferMode, done: ((TransferResult) -> Void)? = nil) {
        // 同时选中了文件夹和它里面的项目时只搬文件夹（否则文件夹先搬走，里面的项目就报「No such file」）
        let urls = withoutNested(urls)
        guard !urls.isEmpty else { return }
        let p = beginOp(mode == .move ? "移动" : "拷贝", count: urls.count, kind: (mode == .move || (mode == .auto && sameVolume(urls[0], dir))) ? .move : .copy, first: urls[0].lastPathComponent, dest: dir.lastPathComponent)
        let srcDirs = Array(Set(urls.map { $0.deletingLastPathComponent() }))
        opQueue.async { [weak self] in
            let r = FileOps.transfer(urls, to: dir, mode: mode, progress: p, resolve: { n, mv in self?.askConflict(n, move: mv, multi: p.conflictsLeft > 1) ?? (.stop, false) })
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.endOp(p); resetDisplayNames()
                var ops: [UndoOp] = []
                if !r.replaced.isEmpty { ops.append(.trashed(r.replaced)) }
                if !r.moved.isEmpty { ops.append(.moved(r.moved)) }
                if !r.copied.isEmpty { ops.append(.created(r.copied)) }
                if ops.count == 1 { self.recordUndo(ops[0]) } else if !ops.isEmpty { self.recordUndo(.group(ops)) }
                self.removeFromLists(r.moved.map { $0.0 })
                let landed = Set((r.moved.map { $0.1 } + r.copied).map { $0.standardizedFileURL })
                for p in self.panes { for t in p.tabs where t.path.path == dir.standardizedFileURL.path && !landed.isEmpty { t.selection = landed } }
                self.reload(dirs: [dir] + srcDirs)
                if !r.errs.isEmpty { self.showError("部分操作未完成", r.errs.joined(separator: "\n")) }
                done?(r)
            }
        }
    }
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let p = beginOp("移到废纸篓", count: urls.count, kind: .trash, first: urls[0].lastPathComponent)
        let dirs = Array(Set(urls.map { $0.deletingLastPathComponent() }))
        opQueue.async {
            let r = FileOps.trash(urls, progress: p)
            DispatchQueue.main.async {
                self.endOp(p)
                if !r.done.isEmpty { self.recordUndo(.trashed(r.done)) }
                self.removeFromLists(r.done.map { $0.0 })
                self.reload(dirs: dirs)
                if !r.errs.isEmpty { self.showError("无法移到废纸篓", r.errs.joined(separator: "\n"), fda: r.perm) }
            }
        }
    }
    /// 访达行为：在当前显示的文件夹（分栏视图里是最右侧的文件夹）新建「未命名文件夹」，选中并直接进入就地重命名。
    func newFolder(in target: URL? = nil) {
        let tab = activeTab
        let dir = target ?? (tab.viewMode == .column && !tab.isGlobalSearch ? tab.columnChain.last : nil) ?? tab.path
        do {
            let u = try FileOps.newFolder(in: dir).realFileURL
            recordUndo(.created([u]))
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
            recordUndo(.group([.created([r.folder]), .moved(r.moved)]))
            let u = r.folder.realFileURL
            activeTab.selection = [u]; activeTab.anchor = u
            reloadVisible(); beginRename(u)
        } catch { showError("无法新建文件夹", error.localizedDescription, fda: isPermissionError(error)) }
    }
    func makeAlias(_ urls: [URL]) {
        var made: [URL] = [], errs: [String] = []
        for u in urls { do { made.append(try FileOps.makeAlias(u)) } catch { errs.append("「\(u.lastPathComponent)」：\(error.localizedDescription)") } }
        if !made.isEmpty { recordUndo(.created(made)); activeTab.selection = Set(made.map { $0.realFileURL }) }
        reloadVisible()
        if !errs.isEmpty { showError("无法制作替身", errs.joined(separator: "\n")) }
    }
    /// 就地重命名（画廊视图没有可编辑的名称，退回到重命名窗口）
    func beginRename(_ u: URL) {
        if activeTab.viewMode == .gallery && !activeTab.isGlobalSearch { renameReq = RenameReq(url: u) }
        else { inlineRename = u.realFileURL }
    }
    func rename(_ u: URL, to name: String) {
        resetDisplayNames()
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != u.lastPathComponent else { return }
        do {
            let dst = try FileOps.rename(u, to: name); recordUndo(.rename(u, dst))
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
                    self.recordUndo(.created([out]))
                    for p in self.panes { for t in p.tabs where t.path.path == out.deletingLastPathComponent().path { t.selection = [out.standardizedFileURL] } }
                    self.reloadVisible()
                case .failure(let e): self.showError("无法压缩", e.localizedDescription)
                }
            }
        }
    }
    /// 撤销移动 / 改名后，文件架指回原来的位置
    func shelfFollowUndo(_ op: UndoOp) {
        switch op {
        case .moved(let pairs), .renamedBatch(let pairs), .trashed(let pairs): shelf.relocate(pairs.map { ($0.1, $0.0) })
        case .rename(let a, let b): shelf.relocate([(b, a)])
        case .group(let ops): ops.reversed().forEach(shelfFollowUndo)
        case .created: break
        }
    }
    // MARK: v0.6 批量重命名
    private func showBatchRenamePanel() {
        let had = renamePanel != nil
        renamePanel?.close(); renamePanel = nil
        let host = responders[active].v?.window ?? testWindow ?? NSApp?.mainWindow
        if let m = batchRename, let w = host {
            let p = BatchRenamePanel(m: m, app: self); renamePanel = p; p.present(on: w)
        } else if had { DispatchQueue.main.async { self.focusActiveTable() } }
    }
    /// 改名后让各标签页的选中项跟着新名字（按标准路径找，换成新名称，URL 写法保持不变）
    /// 选中项本来就取自列表，先直接按 URL 查；写法不同的才按名称筛选后做标准化比较。拼新 URL 时注明是否文件夹，不去查磁盘
    /// （原来逐个标准化 + appendingPathComponent 查磁盘，1000 项要 45ms）
    func remapSelection(_ pairs: [(URL, URL)]) {
        guard !pairs.isEmpty else { return }
        let direct = Dictionary(pairs.map { ($0.0, $0.1.lastPathComponent) }, uniquingKeysWith: { a, _ in a })
        var oldNames: Set<String>?, std: [String: String]?
        func newName(_ u: URL) -> String? {
            if let n = direct[u] { return n }
            if oldNames == nil { oldNames = Set(pairs.map { $0.0.lastPathComponent }) }
            guard oldNames!.contains(u.lastPathComponent) else { return nil }
            if std == nil { std = Dictionary(pairs.map { ($0.0.standardizedFileURL.path, $0.1.lastPathComponent) }, uniquingKeysWith: { a, _ in a }) }
            return std![u.standardizedFileURL.path]
        }
        for pn in panes { for t in pn.tabs where !t.selection.isEmpty {
            var changed = false
            let sel = Set(t.selection.map { u -> URL in
                guard let n = newName(u) else { return u }
                changed = true
                return u.deletingLastPathComponent().appendingPathComponent(n, isDirectory: u.hasDirectoryPath)
            })
            if changed { t.selection = sel }
        } }
    }
    func beginBatchRename(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        palette.close(refocus: false)
        batchRename = BatchRenameModel(urls: urls)
    }
    /// 在后台按预览执行改名（界面不卡）；成功后整批作为一步放进撤销（⌘Z 一次改回）
    func applyBatchRename(_ rows: [RenameRow], done: ((Bool) -> Void)? = nil) {
        let ok = rows.filter { $0.status == .ok }
        guard !ok.isEmpty, !rows.contains(where: { $0.status.isBlocking }) else { NSSound.beep(); done?(false); return }
        resetDisplayNames()
        let p = beginOp("重命名", count: ok.count, first: ok[0].old)
        opQueue.async {
            p.markRunning()
            let res = Result { try BatchRename.apply(rows, progress: p) }
            DispatchQueue.main.async {
                self.endOp(p); resetDisplayNames()
                switch res {
                case .success(let pairs):
                    if !pairs.isEmpty { self.recordUndo(.renamedBatch(pairs)) }
                    self.lastBatchRename = pairs
                    // 选中项跟着新名字走：只换最后一段名称，保留列表里 URL 原来的写法（/tmp 与 /private/tmp 这类同一位置的两种写法不会对不上）
                    self.remapSelection(pairs)
                    self.shelf.relocate(pairs)
                    self.reload(dirs: Array(Set(pairs.map { $0.0.deletingLastPathComponent() })))
                    done?(true)
                case .failure(let e):
                    self.showError("无法重命名", e.localizedDescription, fda: isPermissionError(e))
                    self.reloadVisible(); done?(false)
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
        if tagColor(tag) == nil && !customTags.contains(tag) { customTags.append(tag); Settings.customTags = customTags }
        reloadVisible()
        for p in panes { for t in p.tabs where t.isGlobalSearch { t.refreshSearch() } }
        if !errs.isEmpty { showError("无法修改标签", errs.joined(separator: "\n")) }
    }
    func undo() {
        resetDisplayNames()
        guard let op = undoStack.popLast() else { NSSound.beep(); return }
        performUndoOrRedo(op, isRedo: false)
    }
    func redo() {
        resetDisplayNames()
        guard let op = redoStack.popLast() else { NSSound.beep(); return }
        performUndoOrRedo(op, isRedo: true)
    }
    private func performUndoOrRedo(_ op: UndoOp, isRedo: Bool) {
        let verb = isRedo ? "重做" : "撤销"
        let p = beginOp(verb, count: 1)
        opQueue.async {
            p.markRunning()
            var put: [URL] = [], inv: UndoOp?
            let err: String? = {
                do { let r = try FileOps.undoWithInverse(op); inv = r.inverse; put = r.trashed; return nil }
                catch { return error.localizedDescription }
            }()
            DispatchQueue.main.async {
                self.lastUndoTrashed = put
                self.endOp(p)
                if let e = err { self.showError("无法\(verb)", e) }
                if let inv = inv {
                    if isRedo {
                        self.undoStack.append(inv)
                        if self.undoStack.count > Self.maxUndoDepth { self.undoStack.removeFirst(self.undoStack.count - Self.maxUndoDepth) }
                    } else {
                        self.redoStack.append(inv)
                    }
                    self.shelfFollowUndo(op)
                    if case .renamedBatch(let pairs) = op { self.remapSelection(pairs.map { ($0.1, $0.0) }) }
                }
                self.reloadVisible()
            }
        }
    }
}
