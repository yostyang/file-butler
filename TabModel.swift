import SwiftUI
import AppKit

// MARK: - Tab
final class TabModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var path: URL
    var items: [FileItem] = []
    @Published var display: [FileItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var permissionDenied = false
    @Published var selection: Set<URL> = [] { didSet { if selection != oldValue { app?.selectionDidChange(self); let has = !selection.isEmpty
        // 工具栏按钮的可用状态放到下一轮刷新（不和列表的大批量更新挤在同一帧）
        if has != chrome.hasSelection { DispatchQueue.main.async { [weak self] in guard let self = self else { return }; self.chrome.set(\.hasSelection, !self.selection.isEmpty) } } } } }
    @Published var version = 0
    @Published var viewMode: ViewMode { didSet { app?.saveState(); chrome.set(\.viewMode, viewMode) } }
    @Published var groupKey: GroupKey = .none { didSet { if groupKey != oldValue { cacheVersion = -1; version += 1; chrome.set(\.groupKey, groupKey) } } }
    @Published var searchText = "" { didSet { chrome.set(\.searchText, searchText) } }
    /// 与访达一致：默认搜「这台 Mac」
    @Published var searchScope: SearchScope = .mac { didSet { if searchScope != oldValue { refreshSearch() } } }
    @Published var matchMode: SearchMatch = .name { didSet { if matchMode != oldValue { refreshSearch(); chrome.set(\.matchMode, matchMode) } } }
    @Published var criteria: [SearchCriterion] = [] { didSet { if criteria != oldValue { criteriaChanged() } } }
    @Published var tagFilter: String? { didSet { chrome.set(\.tagFilter, tagFilter) } }
    /// 工具栏只观察这个小对象：选中、列表内容变化时工具栏不重排（大目录 ⌘A、批量操作不卡）
    let chrome = TabChrome()
    var searchResults: [FileItem] = []
    @Published var searching = false
    /// 分栏视图的各栏内容（键盘导航读取；视图持有，这里弱引用）
    weak var columnLoader: ColumnLoader?
    @Published var columnChain: [URL] = []
    var back: [URL] = [], fwd: [URL] = []
    var sortKey: SortKey = .name { didSet { chrome.set(\.sortKey, sortKey) } }
    var asc = true { didSet { chrome.set(\.asc, asc) } }
    var anchor: URL?
    var freeBytes: Int64?
    private var cacheVersion = -1
    private var indexVersion = -1
    private var groupsCache: [(String, [FileItem])] = []
    private var orderCache: [URL] = []
    private var indexCache: [URL: Int] = [:]
    private func fillGroupCache() {
        guard cacheVersion != version else { return }
        cacheVersion = version
        groupsCache = groupItems(display, by: groupKey)
        orderCache = groupKey == .none ? display.map { $0.url } : groupsCache.flatMap { $0.1 }.map { $0.url }
    }
    private func fillIndexCache() {
        guard indexVersion != version else { return }
        indexVersion = version
        indexCache = Dictionary(display.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }
    /// 分组结果与选中索引分别按 version 惰性缓存：打开或刷新目录时若无选中项，不必每次构建整张索引表
    var groups: [(String, [FileItem])] { fillGroupCache(); return groupsCache }
    var groupedOrder: [URL] { fillGroupCache(); return orderCache }
    weak var app: AppState?
    private(set) var isReloading = false
    private var loadToken = 0, reloadGen = 0, pending = false, searchToken = 0
    private var watcher: FolderWatcher?, watchedPath = ""
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    var title: String {
        if let t = tagFilter { return "标签：\(t)" }
        let p = viewMode == .column ? (columnChain.last ?? path) : path
        return p.path == "/" ? "/" : cachedDisplayName(p.path)
    }
    /// 路径栏显示的目标（访达行为）：分栏视图里是最深的选中项；其他视图是当前文件夹 + 单个选中项。
    var pathTarget: URL {
        if tagFilter == nil, selection.count == 1, let s = selection.first { return s }
        if viewMode == .column, let c = columnChain.last { return c }
        return path
    }
    /// 这些条件只能靠 Spotlight 完成（访达也一样）：搜内容、或加了「内容」条件行。
    /// 此时即使范围是「当前文件夹」，也用 Spotlight 在该文件夹内递归搜索（与访达的文件夹范围一致）。
    var needsSpotlight: Bool { tagFilter != nil || matchMode == .contents || criteria.contains { $0.field == .contents } }
    var isGlobalSearch: Bool { tagFilter != nil || (searchActive && (searchScope != .folder || needsSpotlight)) }
    var searchActive: Bool { tagFilter != nil || !searchText.isEmpty || !criteria.isEmpty }
    var selectedItems: [FileItem] {
        guard !selection.isEmpty else { return [] }
        fillIndexCache()
        var inDisplay: [(Int, FileItem)] = [], rest: [URL] = []
        for u in selection { if let i = indexCache[u] { inDisplay.append((i, display[i])) } else { rest.append(u) } }
        return inDisplay.sorted { $0.0 < $1.0 }.map { $0.1 } + rest.sorted { $0.path < $1.path }.filter { FileManager.default.fileExists(atPath: $0.path) }.map(makeItem)
    }
    /// 状态栏用的选中摘要：只查已加载的列表，不逐个读取磁盘（大量选中时也不卡）
    var selectionSummary: (count: Int, size: Int64, hasFolder: Bool) {
        guard !selection.isEmpty else { return (0, 0, false) }
        fillIndexCache()
        var size: Int64 = 0, folder = false
        for u in selection { if let i = indexCache[u] { let it = display[i]; if it.isFolderLike { folder = true } else { size += it.size } } }
        return (selection.count, size, folder)
    }
    var selectedURLs: [URL] {
        guard !selection.isEmpty else { return [] }
        fillIndexCache()
        var inDisplay: [(Int, URL)] = [], rest: [URL] = []
        for u in selection { if let i = indexCache[u] { inDisplay.append((i, u)) } else { rest.append(u) } }
        return inDisplay.sorted { $0.0 < $1.0 }.map { $0.1 } + rest.sorted { $0.path < $1.path }
    }

    init(path: URL, app: AppState, mode: ViewMode = .list) {
        self.path = path.standardizedFileURL; self.app = app; self.viewMode = mode
        sortKey = Settings.defaultSortKey
        asc = Settings.defaultSortAsc
        chrome.viewMode = mode; chrome.sortKey = sortKey; chrome.asc = asc
        reload()
    }
    deinit { watcher?.stop(); query?.stop(); observers.forEach { NotificationCenter.default.removeObserver($0) } }

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
    func setSort(_ k: SortKey, asc a: Bool) {
        guard k != sortKey || a != asc else { return }
        sortKey = k; asc = a; resort()
    }
    func resort() {
        items = sortItems(items, key: sortKey, asc: asc); recompute()
        Settings.defaultSortKey = sortKey; Settings.defaultSortAsc = asc
    }
    func recompute() {
        if isGlobalSearch { display = sortItems(searchResults.filter(clientMatch), key: sortKey, asc: asc) }
        else if searchActive { display = items.filter { (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) && clientMatch($0) } }
        else { display = items }
        version += 1
    }
    /// 客户端逐条套用搜索条件。「内容」条件由 Spotlight 谓词承担，客户端不重复读文件。
    func clientMatch(_ it: FileItem) -> Bool {
        criteria.allSatisfy { $0.field == .contents || matchCriterion(it, $0) }
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
        reloadGen += 1; pending = false; isReloading = true
        pruneMissing()
        // 分栏视图里右侧各栏的列表也一起重读（以前只重读第一栏，右侧栏留着已经移走的旧内容）
        if viewMode == .column, let l = columnLoader { for c in columnChain { l.load(c, hidden: app?.showHidden ?? false, sortKey: sortKey, asc: asc) } }
        loadToken += 1; let tok = loadToken, p = path, hidden = app?.showHidden ?? false
        // 只有列表为空时才显示「加载中」（避免每次刷新都多一轮界面重绘）
        if items.isEmpty && !loading { loading = true }
        let key = sortKey, ascending = asc, grp = groupKey, searchingNow = searchActive
        DispatchQueue.global(qos: .userInitiated).async {
            let (res, err, denied) = loadDirectory(p, hidden: hidden)
            let sorted = sortItems(res, key: key, asc: ascending)   // 排序也在后台完成
            let preGrouped = (!searchingNow && grp != .none) ? groupItems(sorted, by: grp) : nil
            let preOrder = preGrouped?.flatMap { $0.1 }.map { $0.url }
            let free = freeSpace(p)
            let all = Set(res.map { $0.url })   // 选中项比对用的集合也在后台建好
            DispatchQueue.main.async {
                guard tok == self.loadToken else { return }
                self.isReloading = false
                if self.error != err { self.error = err }
                if self.permissionDenied != denied { self.permissionDenied = denied }
                self.freeBytes = free
                let newItems = key == self.sortKey && ascending == self.asc ? sorted : sortItems(res, key: self.sortKey, asc: self.asc)
                // 内容没变（例如目录监视的重复通知）：什么都不更新，界面不重绘
                if newItems == self.items && !self.items.isEmpty && (self.cacheVersion >= 0 || self.indexVersion >= 0 || !self.display.isEmpty) {
                    if self.loading { self.loading = false }
                    self.watch(); return
                }
                self.items = newItems
                let dirPath = p.path
                if !self.selection.isEmpty && !self.selection.isSubset(of: all) {
                    // 写法不同的同一文件（/tmp 与 /private/tmp 等，例如「前往」或命令面板选中的文件）按名称对上并换成列表里的写法；真正不在了的才去掉
                    let map = matchByName(self.selection.filter { !all.contains($0) }, dir: p, display: newItems)
                    let keep = Set(self.selection.compactMap { u -> URL? in all.contains(u) ? u : (map[u] ?? (u.deletingLastPathComponent().path != dirPath ? u : nil)) })
                    if keep != self.selection { self.selection = keep; if let a = self.anchor, let b = map[a] { self.anchor = b } }
                }
                if self.loading { self.loading = false }
                self.recompute()
                if let pg = preGrouped, let po = preOrder, !self.searchActive, self.groupKey == grp, key == self.sortKey, ascending == self.asc {
                    self.groupsCache = pg; self.orderCache = po; self.cacheVersion = self.version
                }
                self.app?.noteTags(res)
                if !self.selection.isEmpty { self.app?.selectionDidChange(self) }
                self.watch()
            }
        }
    }
    /// 显示的位置在磁盘上已经不存在（被移走、改名、删除）时不再显示它（访达行为）：
    /// 当前文件夹不在了 → 退到最近的仍存在的上级；分栏视图里不在了的栏截掉；不在了的选中项去掉。
    /// 只检查当前文件夹、分栏链和不在当前文件夹里的选中项（数量都很少），不读目录。
    func pruneMissing() {
        let fm = FileManager.default
        if !isGlobalSearch, path.path != "/", !fm.fileExists(atPath: path.path) {
            var p = path.deletingLastPathComponent()
            while p.path != "/" && !fm.fileExists(atPath: p.path) { p = p.deletingLastPathComponent() }
            path = p.standardizedFileURL; columnChain = []; selection = []; anchor = nil; error = nil; permissionDenied = false
            return
        }
        if let i = columnChain.firstIndex(where: { !fm.fileExists(atPath: $0.path) }) {
            columnChain = Array(columnChain.prefix(i))
        }
        let dir = path.path
        if !selection.isEmpty && selection.count <= 200 {   // 大量选中（全选几千项）时不逐个检查，避免卡主线程
            let keep = selection.filter { $0.deletingLastPathComponent().path == dir || fm.fileExists(atPath: $0.path) }
            if keep.count != selection.count { selection = keep; if let a = anchor, !keep.contains(a) { anchor = nil } }
        }
    }
    private func watch() {
        if watcher == nil {
            let w = FolderWatcher()
            w.roots = { [weak self] in
                guard let self = self else { return [] }
                return [self.path.path] + self.columnChain.map { $0.path }
            }
            w.onChange = { [weak self] in self?.scheduleReload() }
            watcher = w
        }
        // 路径没变时只更新 roots 闭包用到的 columnChain，不必重建 FSEvent 流（它会递归收到子路径事件）
        if watchedPath != path.path {
            watchedPath = path.path
            watcher?.start(path: path.path)
        }
    }
    private func scheduleReload() {
        if pending { return }; pending = true
        let gen = reloadGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self, self.reloadGen == gen else { return }
            // 后台文件操作进行中：先不刷新（操作结束时会统一刷新一次），避免批量操作时反复重载列表
            if self.app?.progress != nil { self.pending = false; self.scheduleReload(); return }
            self.pending = false; self.reload()
        }
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
            // 名称搜索走快速路径：子文件夹→后台枚举，整台 Mac→searchfs 卷宗目录；内容/标签仍需 Spotlight
            if !self.needsSpotlight {
                if self.searchScope == .mac, FastSearch.catalogSupported { self.startCatalogSearch() } else { self.startEnumSearch() }
                return
            }
            self.startQuery()
        }
    }
    func showTag(_ t: String) { searchText = ""; matchMode = .name; criteria = []; tagFilter = t; selection = []; refreshSearch() }
    func clearSearch() { searchText = ""; matchMode = .name; tagFilter = nil; criteria = []; stopQuery(); searchResults = []; searching = false; recompute() }
    func criteriaChanged() { if isGlobalSearch { refreshSearch() } else { recompute() } }
    func addCriterion() { criteria.append(SearchCriterion()) }
    func removeCriterion(_ id: UUID) { criteria.removeAll { $0.id == id } }
    /// 侧栏「已存搜索」点开：把整套搜索状态搬到当前栏（访达智能文件夹行为）
    func applySaved(_ s: SavedSearch) {
        matchMode = s.matchMode; criteria = s.criteria; searchScope = s.scope; tagFilter = nil; selection = []
        searchText = s.text; refreshSearch()
    }
    /// 快速路径 1：子文件夹递归枚举——直接扫文件系统，几十毫秒出第一批结果
    private func startEnumSearch() {
        let root = path, q = searchText, hidden = app?.showHidden ?? false, tok = searchToken
        searchResults = []
        FastSearch.enumerate(root: root, query: q, showHidden: hidden, isCancelled: { [weak self] in self?.searchToken != tok },
            onBatch: { [weak self] urls in
                let its = urls.map(makeItem).filter { self?.clientMatch($0) ?? false }
                DispatchQueue.main.async { guard let self = self, tok == self.searchToken else { return }
                    self.searchResults += its; self.recompute() }
            },
            done: { [weak self] in DispatchQueue.main.async {
                guard let self = self, tok == self.searchToken else { return }
                self.searching = false; self.recompute() } })
    }
    /// 快速路径 2：整台 Mac 名称搜索——searchfs(2) 扫 APFS 卷宗目录；不支持/出错回退 Spotlight
    private func startCatalogSearch() {
        let q = searchText, hidden = app?.showHidden ?? false, tok = searchToken
        searchResults = []
        FastSearch.catalogSearch(query: q, showHidden: hidden, limit: 2000, isCancelled: { [weak self] in self?.searchToken != tok },
            onBatch: { [weak self] urls in
                let its = urls.map(makeItem).filter {
                    $0.name.localizedCaseInsensitiveContains(q) && (self?.clientMatch($0) ?? false)
                }
                DispatchQueue.main.async { guard let self = self, tok == self.searchToken else { return }
                    self.searchResults += its; self.recompute() }
            },
            done: { [weak self] ok in DispatchQueue.main.async {
                guard let self = self, tok == self.searchToken else { return }
                if !ok { self.startQuery(); return }
                self.searching = false; self.recompute() } })
    }
    private func stopQuery() {
        searchToken += 1   // 同时作废进行中的枚举/卷宗搜索批
        query?.stop(); query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    private func startQuery() {
        stopQuery()
        let q = NSMetadataQuery()
        if let t = tagFilter {
            q.predicate = criteria.isEmpty ? NSPredicate(format: "kMDItemUserTags == %@", t)
                : NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "kMDItemUserTags == %@", t)] + criteria.compactMap { $0.spotlight })
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        } else {
            var preds: [NSPredicate] = []
            if !searchText.isEmpty {
                preds.append(matchMode == .contents
                    ? NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", searchText)
                    : NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(searchText)*"))
            }
            preds += criteria.compactMap { $0.spotlight }
            q.predicate = preds.isEmpty ? NSPredicate(value: true)
                : (preds.count == 1 ? preds[0] : NSCompoundPredicate(andPredicateWithSubpredicates: preds))
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

    /// 把选中项换成列表里的写法（下一轮主线程再改，避免在界面刷新过程中改动；选择已经变了就不动）
    func adoptSelectionForms(_ map: [URL: URL], expected: Set<URL>) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.selection == expected else { return }
            self.selection = Set(expected.map { map[$0] ?? $0 })
            if let a = self.anchor, let b = map[a] { self.anchor = b }
        }
    }
}

final class OpStatus: ObservableObject { @Published var text: String? }
final class TabChrome: ObservableObject {
    @Published var viewMode: ViewMode = .list
    @Published var groupKey: GroupKey = .none
    @Published var sortKey: SortKey = .name
    @Published var asc = true
    @Published var searchText = ""
    @Published var tagFilter: String?
    @Published var matchMode: SearchMatch = .name
    @Published var hasSelection = false
    func set<T: Equatable>(_ k: ReferenceWritableKeyPath<TabChrome, T>, _ v: T) { if self[keyPath: k] != v { self[keyPath: k] = v } }
}

final class PaneModel: ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var current = 0
    var tab: TabModel { tabs[max(0, min(current, tabs.count - 1))] }
}
