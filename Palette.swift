import SwiftUI
import AppKit

// MARK: - v0.6 命令面板（⌘K）：一个键盘面板里找文件 / 文件夹、执行命令。
// 只搜已经在内存里的列表（两栏当前文件夹、最近访问、书签、个人收藏、文件架）+ 当前文件夹下几层的即时扫描；
// 不建索引、没有后台常驻任务；关闭面板立即取消正在进行的扫描。

struct PaletteCommand {
    let title: String, keywords: String, symbol: String, shortcut: String
    let run: () -> Void
}
struct FileCand: Hashable { let url: URL; let isDir: Bool; let source: String }

struct PaletteItem: Identifiable {
    enum Kind { case command, folder, file, path }
    let id: String
    let title: String, subtitle: String, symbol: String, shortcut: String
    let kind: Kind
    let score: Int
    let run: (Bool) -> Void        // 参数：是否按住 ⌘（⌘↩ 用默认 App 打开文件）
    var kindLabel: String { switch kind { case .command: return "命令"; case .folder: return "文件夹"; case .file: return "文件"; case .path: return "路径" } }
}

enum PaletteEngine {
    /// 匹配分数：完全相同 > 前缀 > 词首包含 > 包含 > 按顺序出现（模糊）；不匹配 = nil
    static func score(_ rawQ: String, _ s: String) -> Int? {
        let q = rawQ.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return 0 }
        let ss = s.lowercased()
        if ss == q { return 1000 }
        if ss.hasPrefix(q) { return 800 - min(ss.count, 200) }
        if let r = ss.range(of: q) {
            let pos = ss.distance(from: ss.startIndex, to: r.lowerBound)
            let prev = ss[ss.index(before: r.lowerBound)]
            let wordStart = " -_./（(·".contains(prev)
            return (wordStart ? 650 : 500) - min(pos, 200)
        }
        let a = Array(ss), b = Array(q)
        var j = 0, last = -1, gaps = 0
        for (i, c) in a.enumerated() where j < b.count { if c == b[j] { if last >= 0 { gaps += i - last - 1 }; last = i; j += 1 } }
        guard j == b.count else { return nil }
        return max(1, 300 - gaps * 5 - min(a.count, 100))
    }
    static func abbreviate(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
    /// 以「/」或「~」开头的输入当作路径；存在才返回
    static func pathQuery(_ q: String) -> URL? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/") || t.hasPrefix("~") else { return nil }
        let u = URL(fileURLWithPath: (t as NSString).expandingTildeInPath).standardizedFileURL
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    /// 当前可用的命令（不可用的不列出）
    static func commands(_ app: AppState) -> [PaletteCommand] {
        let tab = app.activeTab, sel = tab.selectedURLs, home = FileManager.default.homeDirectoryForCurrentUser
        var c: [PaletteCommand] = []
        func add(_ t: String, _ k: String, _ s: String, _ sc: String = "", _ r: @escaping () -> Void) { c.append(PaletteCommand(title: t, keywords: k, symbol: s, shortcut: sc, run: r)) }
        if !tab.isGlobalSearch { add("新建文件夹", "new folder xjwjj", "folder.badge.plus", "⇧⌘N") { app.newFolder() } }
        add("新建标签页", "new tab", "plus.square.on.square", "⌘T") { app.newTab() }
        for (i, m) in ViewMode.allCases.enumerated() where tab.viewMode != m {
            add("\(m.title)显示方式", "view \(m.rawValue) 视图 显示", m.symbol, "⌘\(i + 1)") { app.setViewMode(m) }
        }
        add(app.showHidden ? "不显示隐藏文件" : "显示隐藏文件", "hidden files dot 隐藏", "eye", "⇧⌘.") { app.showHidden.toggle() }
        add(app.showPreview ? "隐藏预览" : "显示预览", "preview info 预览 信息", "sidebar.right", "⇧⌘P") { app.showPreview.toggle() }
        add(app.showPathBar ? "隐藏路径栏" : "显示路径栏", "path bar 路径", "chevron.right.2", "⌥⌘P") { app.showPathBar.toggle() }
        add(app.dual ? "切换为单栏" : "切换为双栏", "dual pane single 双栏 单栏", "rectangle.split.2x1", "⌥⌘U") { app.dual.toggle() }
        add("前往文件夹…", "go to path 路径 前往", "arrow.right.circle", "⇧⌘G") { app.editingPane = app.active }
        add(sel.isEmpty ? "拷贝当前文件夹的路径" : "拷贝路径", "copy path 路径", "link") { copyPaths(sel.isEmpty ? [tab.path] : sel) }
        if !sel.isEmpty {
            add(sel.count == 1 ? "批量重命名…" : "批量重命名 \(sel.count) 个项目…", "rename batch 重命名 改名", "character.cursor.ibeam") { app.beginBatchRename(sel) }
            add(sel.count == 1 ? "加入文件架" : "把 \(sel.count) 个项目加入文件架", "shelf add 文件架", "tray.and.arrow.down") { app.addToShelf(sel) }
            add("在访达中显示", "reveal finder 访达", "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(sel) }
        }
        add(app.shelf.visible ? "隐藏文件架" : "显示文件架", "shelf 文件架", "tray") { app.shelf.visible.toggle() }
        if !app.shelf.items.isEmpty {
            let n = app.shelf.items.count
            add("文件架：拷贝 \(n) 项到当前文件夹", "shelf copy 文件架 拷贝", "doc.on.doc") { app.shelfTransfer(move: false) }
            add("文件架：移动 \(n) 项到当前文件夹", "shelf move 文件架 移动", "arrow.right.doc.on.clipboard") { app.shelfTransfer(move: true) }
            add("清空文件架（不改动文件）", "shelf clear 文件架 清空", "xmark.bin") { app.shelf.clear() }
        }
        add("搜索当前文件夹", "find search 搜索", "magnifyingglass", "⌘F") { app.searchFocus += 1 }
        add("空间分析", "disk usage size 空间", "chart.pie", "⌥⌘S") { app.sizeReq = SizeReq(url: tab.path) }
        add("把当前文件夹加入书签", "bookmark 书签", "bookmark", "⇧⌘B") { app.addBookmark() }
        if !app.undoStack.isEmpty { add("撤销上一步文件操作", "undo 撤销", "arrow.uturn.backward", "⌥⌘Z") { app.undo() } }
        add("前往：个人", "home 个人", "house", "⇧⌘H") { app.go(home) }
        add("前往：桌面", "desktop 桌面", "menubar.dock.rectangle", "⇧⌘D") { app.go(home.appendingPathComponent("Desktop")) }
        add("前往：下载", "downloads 下载", "arrow.down.circle", "⌥⌘L") { app.go(home.appendingPathComponent("Downloads")) }
        add("前往：应用程序", "applications 应用", "square.grid.3x3", "⇧⌘A") { app.go(URL(fileURLWithPath: "/Applications")) }
        return c
    }
    /// 打开面板时拍一份内存里已有的列表（不读磁盘）
    static func snapshot(_ app: AppState) -> [FileCand] {
        var out: [FileCand] = [], seen = Set<String>()
        func put(_ u: URL, _ d: Bool, _ s: String) { let p = u.standardizedFileURL.path; if seen.insert(p).inserted { out.append(FileCand(url: u.standardizedFileURL, isDir: d, source: s)) } }
        let panes = app.dual ? [app.active, 1 - app.active] : [app.active]
        for i in panes { for it in app.panes[i].tab.display.prefix(20000) { put(it.url, it.isFolderLike, i == app.active ? "当前文件夹" : "另一栏") } }
        for u in app.visibleRecents { put(u, true, "最近访问") }
        for u in app.bookmarks { put(u, true, "书签") }
        for u in app.favorites { put(u, true, "个人收藏") }
        for u in app.shelf.items { var d: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &d); put(u, d.boolValue, "文件架") }
        return out
    }
    static func fileItem(_ f: FileCand, score: Int, app: AppState) -> PaletteItem {
        return PaletteItem(id: "file:" + f.url.path, title: f.url.path == "/" ? rootVolumeName : f.url.lastPathComponent,
                           subtitle: abbreviate(f.url.deletingLastPathComponent().path) + " · " + f.source,
                           symbol: f.isDir ? "folder.fill" : "doc", shortcut: "", kind: f.isDir ? .folder : .file, score: score) { alt in
            if alt && !f.isDir { NSWorkspace.shared.open(f.url) } else { app.go(f.url) }
        }
    }
    /// 排序后的结果：空输入时先列最近访问的文件夹，再列命令
    static func rank(_ query: String, commands: [PaletteCommand], files: [FileCand], app: AppState, limit: Int = 60) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [PaletteItem] = []
        if let p = pathQuery(q) {
            out.append(PaletteItem(id: "path:" + p.path, title: "前往 " + abbreviate(p.path), subtitle: "输入的路径", symbol: "arrow.right.circle.fill", shortcut: "↩", kind: .path, score: 2000) { _ in app.go(p) })
        }
        if q.isEmpty {
            for f in files.filter({ $0.source == "最近访问" }).prefix(5) { out.append(fileItem(f, score: 0, app: app)) }
            for c in commands { out.append(PaletteItem(id: "cmd:" + c.title, title: c.title, subtitle: "", symbol: c.symbol, shortcut: c.shortcut, kind: .command, score: 0) { _ in c.run() }) }
            return Array(out.prefix(limit))
        }
        for c in commands {
            let s = max(score(q, c.title) ?? -1, (score(q, c.keywords) ?? -1) - 50)
            if s >= 0 { out.append(PaletteItem(id: "cmd:" + c.title, title: c.title, subtitle: "", symbol: c.symbol, shortcut: c.shortcut, kind: .command, score: s + 5) { _ in c.run() }) }
        }
        for f in files { if let s = score(q, f.url.lastPathComponent) { out.append(fileItem(f, score: s + (f.isDir ? 2 : 0), app: app)) } }
        // 分数相同：命令 > 文件夹 > 文件，再按名称
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Array(out.prefix(limit))
    }
    /// 当前文件夹往下几层的即时扫描（不建索引）：可取消、有数量和时间上限；不进入包、隐私受保护的文件夹（没有完全磁盘访问权限时）、/Volumes 等
    static func deepScan(root: URL, query: String, showHidden: Bool, token: CancelToken,
                         maxVisit: Int = 20000, maxDepth: Int = 4, maxHits: Int = 200, deadline: TimeInterval = 1.5) -> (hits: [FileCand], visited: Int) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ([], 0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var skip: Set<String> = ["/Volumes", "/System", "/private", "/dev", home + "/Library", home + "/.Trash"]
        if !hasFullDiskAccess() { for d in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library/Mobile Documents"] { skip.insert(home + "/" + d) } }
        let rootPath = root.standardizedFileURL.path
        skip = skip.filter { !(rootPath == $0 || rootPath.hasPrefix($0 + "/")) }   // 已经在这个文件夹里：说明已经能访问
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: opts, errorHandler: { _, _ in true }) else { return ([], 0) }
        var hits: [FileCand] = [], n = 0
        let t0 = Date()
        while let u = e.nextObject() as? URL {
            n += 1
            if token.isCancelled { return ([], n) }
            if n > maxVisit || hits.count >= maxHits { break }
            if n % 256 == 0 && Date().timeIntervalSince(t0) > deadline { break }
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            if isDir && (e.level >= maxDepth || skip.contains(u.standardizedFileURL.path)) { e.skipDescendants() }
            if u.lastPathComponent.localizedCaseInsensitiveContains(q) {
                hits.append(FileCand(url: u.standardizedFileURL, isDir: isDir, source: "子文件夹"))
            }
        }
        return (hits, n)
    }
}

final class PaletteModel: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var query = ""
    @Published private(set) var results: [PaletteItem] = []
    @Published var selected = 0
    @Published private(set) var scanning = false
    weak var app: AppState?
    private(set) var token = CancelToken()
    private var snapshot: [FileCand] = [], deep: [FileCand] = []
    private var commands: [PaletteCommand] = []
    /// 测试用：最近一次扫描访问的条目数
    private(set) var lastVisited = 0
    func toggle() { visible ? close() : open() }
    func open() {
        guard let app = app else { return }
        if let w = app.testWindow ?? NSApplication.shared.keyWindow, w.attachedSheet != nil { NSSound.beep(); return }
        commands = PaletteEngine.commands(app)
        snapshot = PaletteEngine.snapshot(app)
        deep = []; query = ""; selected = 0
        visible = true
        rebuild()
    }
    func close(refocus: Bool = true) {
        token.cancel()
        guard visible else { return }
        visible = false; scanning = false
        results = []; snapshot = []; deep = []; commands = []; query = ""
        if refocus { app?.focusActiveTable() }
    }
    func setQuery(_ q: String) {
        guard visible, q != query else { return }
        query = q; deep = []
        rebuild(); selected = 0
        startScan()
    }
    private func rebuild() {
        guard let app = app else { return }
        let keep = results.indices.contains(selected) ? results[selected].id : nil
        results = PaletteEngine.rank(query, commands: commands, files: snapshot + deep, app: app)
        if let k = keep, let i = results.firstIndex(where: { $0.id == k }) { selected = i } else if selected >= results.count { selected = 0 }
    }
    private func startScan() {
        token.cancel(); let tok = CancelToken(); token = tok
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let app = app, q.count >= 2, PaletteEngine.pathQuery(q) == nil, !q.hasPrefix("/"), !q.hasPrefix("~") else { scanning = false; return }
        let tab = app.activeTab
        guard !tab.isGlobalSearch else { scanning = false; return }
        let root = tab.viewMode == .column ? (tab.columnChain.last ?? tab.path) : tab.path
        let hidden = app.showHidden
        scanning = true
        // 停止输入 0.15 秒后才扫描；期间再输入或关闭面板都会取消
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if tok.isCancelled { return }
            let r = PaletteEngine.deepScan(root: root, query: q, showHidden: hidden, token: tok)
            DispatchQueue.main.async {
                guard let self = self, !tok.isCancelled, self.visible else { return }
                self.lastVisited = r.visited
                self.deep = r.hits; self.scanning = false
                self.rebuild()
            }
        }
    }
    func move(_ d: Int) {
        guard !results.isEmpty else { NSSound.beep(); return }
        selected = (selected + d + results.count) % results.count
    }
    func run(_ i: Int? = nil, alt: Bool = false) {
        let k = i ?? selected
        guard results.indices.contains(k) else { NSSound.beep(); return }
        let it = results[k]
        close(refocus: true)
        DispatchQueue.main.async { it.run(alt) }
    }
}

extension AppState {
    func togglePalette() { palette.toggle() }
}

/// 覆盖在窗口上的命令面板（点面板外关闭）
struct PaletteOverlay: View {
    @ObservedObject var p: PaletteModel
    var body: some View {
        if p.visible {
            ZStack(alignment: .top) {
                Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture { p.close() }
                PaletteCard(p: p).padding(.top, 64)
            }
        }
    }
}

struct PaletteCard: View {
    @ObservedObject var p: PaletteModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
                PaletteField(p: p).frame(height: 26)
                if p.scanning { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 16).frame(height: 54)
            Divider()
            if p.results.isEmpty {
                Text(p.scanning ? "正在查找…" : "没有匹配的文件、文件夹或命令").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(p.results.enumerated()), id: \.element.id) { i, it in
                                PaletteRow(it: it, selected: i == p.selected).id(it.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { p.run(i, alt: NSEvent.modifierFlags.contains(.command)) }
                            }
                        }.padding(6)
                    }
                    .frame(height: min(CGFloat(p.results.count) * 42 + 12, 380))
                    .onChange(of: p.selected) { s in if p.results.indices.contains(s) { proxy.scrollTo(p.results[s].id) } }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑↓ 选择"); Text("↩ 打开 / 执行"); Text("⌘↩ 用默认 App 打开文件"); Text("esc 关闭")
                Spacer()
                Text("只搜当前文件夹及其下几层、最近访问、书签和文件架")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 28)
        }
        .frame(width: 660)
        .background(VisualEffectBG())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .accessibilityIdentifier("command-palette")
    }
}

struct PaletteRow: View {
    let it: PaletteItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: it.symbol).font(.system(size: 14)).frame(width: 24, height: 24)
                .foregroundStyle(it.kind == .command ? AnyShapeStyle(accentGrad) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if !it.subtitle.isEmpty { Text(it.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 8)
            if !it.shortcut.isEmpty {
                Text(it.shortcut).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            }
            Text(it.kindLabel).font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accentA.opacity(0.18) : Color.clear))
    }
}

struct VisualEffectBG: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = .popover; v.blendingMode = .withinWindow; v.state = .active; return v }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// 面板的输入框：AppKit 文本框（macOS 13 也能处理 ↑↓ / 回车 / Esc，中文输入法正常）
final class PaletteTextField: NSTextField {
    weak var model: PaletteModel?
    var focused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        for d in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let s = self, let w = s.window, s.currentEditor() == nil, s.model?.visible == true else { return }
                if w.makeFirstResponder(s) { s.focused = true }
            }
        }
    }
}
struct PaletteField: NSViewRepresentable {
    let p: PaletteModel
    func makeCoordinator() -> C { C(p) }
    func makeNSView(context: Context) -> PaletteTextField {
        let tf = PaletteTextField(string: "")
        tf.model = p
        tf.placeholderString = "搜索文件、文件夹或命令…"
        tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 18); tf.delegate = context.coordinator
        tf.cell?.isScrollable = true; tf.cell?.wraps = false
        tf.setAccessibilityIdentifier("palette-field")
        return tf
    }
    func updateNSView(_ v: PaletteTextField, context: Context) {}
    final class C: NSObject, NSTextFieldDelegate {
        let p: PaletteModel
        init(_ p: PaletteModel) { self.p = p }
        func controlTextDidChange(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            p.setQuery(tf.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): p.move(-1); return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): p.move(1); return true
            case #selector(NSResponder.insertBacktab(_:)): p.move(-1); return true
            case #selector(NSResponder.cancelOperation(_:)): p.close(); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                p.run(alt: NSApp.currentEvent?.modifierFlags.contains(.command) == true); return true
            default:
                // ⌘↩ 在文本框里会变成 noop:
                if NSStringFromSelector(sel) == "noop:", let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 {
                    p.run(alt: e.modifierFlags.contains(.command)); return true
                }
                return false
            }
        }
    }
}
