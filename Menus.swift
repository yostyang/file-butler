import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 右键菜单的统一描述：列表视图渲染成 NSMenu，图标 / 分栏 / 画廊视图渲染成 SwiftUI 菜单，顺序和访达一致。
indirect enum MEntry {
    case item(String, NSImage?, Bool, Bool, () -> Void)   // 标题、图标、是否勾选、是否可用、动作
    case sep
    case sub(String, [MEntry])
    case share([URL])
    case tagRow([URL])
}

func pasteboardFileCount() -> Int {
    if let a = RightClick.app { if let p = a.clipPending { return p.1.count }; if let o = a.ownClip, o.0 == NSPasteboard.general.changeCount { return o.1.count } }
    return (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.count ?? 0
}

func displayNameNoExt(_ u: URL) -> String { u.lastPathComponent }

func openWithEntries(_ urls: [URL], app: AppState) -> [MEntry] {
    guard let first = urls.first else { return [] }
    var out: [MEntry] = []
    let def = NSWorkspace.shared.urlForApplication(toOpen: first)
    var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
    if let d = def { apps.removeAll { $0.path == d.path }; apps.insert(d, at: 0) }
    func entry(_ a: URL, isDefault: Bool) -> MEntry {
        let ic = NSWorkspace.shared.icon(forFile: a.path); ic.size = NSSize(width: 16, height: 16)
        let name = FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: "")
        return .item(isDefault ? "\(name)（默认）" : name, ic, false, true) {
            NSWorkspace.shared.open(urls, withApplicationAt: a, configuration: NSWorkspace.OpenConfiguration()) { _, e in
                if let e = e { DispatchQueue.main.async { app.showError("无法打开", e.localizedDescription) } }
            }
        }
    }
    if let d = def, let f = apps.first, f.path == d.path { out.append(entry(d, isDefault: true)); out.append(.sep); apps.removeFirst() }
    for a in apps.prefix(20) { out.append(entry(a, isDefault: false)) }
    if !apps.isEmpty { out.append(.sep) }
    out.append(.item("其他…", nil, false, true) {
        let p = NSOpenPanel(); p.directoryURL = URL(fileURLWithPath: "/Applications"); p.allowedContentTypes = [.application]; p.prompt = "打开"
        if p.runModal() == .OK, let a = p.url { NSWorkspace.shared.open(urls, withApplicationAt: a, configuration: NSWorkspace.OpenConfiguration()) { _, _ in } }
    })
    return out
}

func sym(_ s: String) -> NSImage? { NSImage(systemSymbolName: s, accessibilityDescription: nil) }

func contextSpec(app: AppState, tab: TabModel, pane: Int, urls: [URL], bgDir: URL? = nil) -> [MEntry] {
    var m: [MEntry] = []
    let other = app.panes[1 - pane].tab.path
    if urls.isEmpty {
        let dir = bgDir ?? tab.path
        let n = pasteboardFileCount()
        m.append(.item("新建文件夹", nil, false, !tab.isGlobalSearch) { app.active = pane; app.newFolder(in: dir) })
        m.append(.item(n > 1 ? "粘贴 \(n) 个项目" : "粘贴项目", nil, false, n > 0 && !tab.isGlobalSearch) { app.active = pane; app.paste(into: dir) })
        m.append(.sep)
        m.append(.item("显示简介", nil, false, true) { app.active = pane; tab.selection = dir.standardizedFileURL.path == tab.path.standardizedFileURL.path ? [] : [dir]; app.showPreview = true })
        m.append(.sep)
        m.append(.sub("显示", ViewMode.allCases.map { v in .item(v.title, nil, tab.viewMode == v, true) { app.active = pane; app.setViewMode(v) } }))
        m.append(.item("使用群组", nil, tab.groupKey != .none, true) { tab.groupKey = tab.groupKey == .none ? .kind : .none })
        if tab.groupKey != .none { m.append(.sub("群组方式", GroupKey.allCases.filter { $0 != .none }.map { g in .item(g.title, nil, tab.groupKey == g, true) { tab.groupKey = g } })) }
        m.append(.sub("排序方式", SortKey.allCases.map { k in .item(k.title, nil, tab.sortKey == k, true) { tab.setSort(k, asc: tab.asc) } }
                      + [.sep, .item("升序", nil, tab.asc, true) { tab.setSort(tab.sortKey, asc: true) }, .item("降序", nil, !tab.asc, true) { tab.setSort(tab.sortKey, asc: false) }]))
        m.append(.item("查看显示选项", nil, false, true) { app.showViewOptions = true })
        m.append(.sep)
        m.append(.sub("文件管家", [
            .item("在访达中显示", nil, false, true) { NSWorkspace.shared.activateFileViewerSelecting([dir]) },
            .item("拷贝路径", nil, false, true) { copyPaths([dir]) },
            .item(app.isPinned(dir) ? "取消置顶" : "置顶到侧边栏", nil, false, true) { app.togglePin(dir) },
            .item("加入书签", nil, false, true) { app.addBookmark(dir) },
            .item("保存当前布局…", nil, false, true) { app.promptSaveLayout() },
            .item("空间分析", nil, false, true) { app.sizeReq = SizeReq(url: dir) },
            .item(app.showHidden ? "不显示隐藏文件" : "显示隐藏文件", nil, false, true) { app.showHidden.toggle() }]))
        return m
    }
    let items = urls.map(makeItem)
    let one = urls.count == 1
    m.append(.item("打开", nil, false, true) { app.openURLs(urls, in: tab) })
    if one, items[0].isFolderLike {
        m.append(.item("在新标签页中打开", nil, false, true) {
            let p = app.panes[pane]; let t = TabModel(path: urls[0], app: app, mode: tab.viewMode)
            p.tabs.insert(t, at: p.current + 1); p.current += 1; app.active = pane; app.touch()
        })
    }
    m.append(.sub("打开方式", openWithEntries(urls, app: app)))
    m.append(.sep)
    m.append(.item("移到废纸篓", nil, false, true) { app.trash(urls) })
    m.append(.sep)
    m.append(.item("显示简介", nil, false, true) { app.active = pane; app.showPreview = true })
    // 访达：选中多个项目时是「重新命名 N 个项目…」（批量重命名）
    if one { m.append(.item("重新命名", nil, false, true) { app.active = pane; app.beginRename(urls[0]) }) }
    else { m.append(.item("重新命名 \(urls.count) 个项目…", nil, false, true) { app.active = pane; app.beginBatchRename(urls) }) }
    m.append(.item(one ? "压缩“\(urls[0].lastPathComponent)”" : "压缩 \(urls.count) 个项目", nil, false, true) { app.zip(urls) })
    m.append(.item("复制", nil, false, true) { app.duplicate(urls) })
    m.append(.item("制作替身", nil, false, true) { app.makeAlias(urls) })
    m.append(.item(one ? "快速查看“\(urls[0].lastPathComponent)”" : "快速查看 \(urls.count) 个项目", nil, false, true) { app.active = pane; app.controllers[pane].quickLook(urls) })
    m.append(.sep)
    m.append(.item(one ? "拷贝“\(urls[0].lastPathComponent)”" : "拷贝 \(urls.count) 个项目", nil, false, true) { app.copyToClipboard(urls, cut: false) })
    m.append(.share(urls))
    m.append(.sep)
    m.append(.tagRow(urls))
    m.append(.item("标签…", nil, false, true) { app.active = pane; tab.selection = Set(urls); app.tagPopoverTick += 1 })
    m.append(.sep)
    // 文件管家独有的功能放在最下面，不打乱访达的使用习惯
    var extra: [MEntry] = [
        .item("剪切", sym("scissors"), false, true) { app.copyToClipboard(urls, cut: true) },
        .item("拷贝路径", sym("link"), false, true) { copyPaths(urls) },
        .item("在访达中显示", sym("magnifyingglass"), false, true) { NSWorkspace.shared.activateFileViewerSelecting(urls) },
        .item("加入文件架", sym("tray.and.arrow.down"), false, true) { app.addToShelf(urls) },
    ]
    if urls.count >= 1 { extra.append(.item("用所选项目新建文件夹", sym("folder.badge.plus"), false, true) { app.active = pane; app.newFolderWithItems(urls) }) }
    if app.dual {
        extra.append(.item("拷贝到另一栏", sym("arrow.right.doc.on.clipboard"), false, true) { app.transfer(urls, to: other, mode: .copy) })
        extra.append(.item("移动到另一栏", sym("arrow.right.square"), false, true) { app.transfer(urls, to: other, mode: .move) })
    }
    if one, items[0].isDir {
        let pinned = app.isPinned(urls[0])
        extra.append(.item(pinned ? "取消置顶" : "置顶到侧边栏", sym(pinned ? "pin.slash" : "pin"), false, true) { app.togglePin(urls[0]) })
        extra.append(.item("加入书签", sym("bookmark"), false, true) { app.addBookmark(urls[0]) })
        extra.append(.item("空间分析", sym("chart.pie"), false, true) { app.sizeReq = SizeReq(url: urls[0]) })
    }
    m += extra
    return m
}

// MARK: NSMenu renderer
final class TagRowView: NSView {
    init(urls: [URL], app: AppState, menu: NSMenu) {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        var x: CGFloat = 20
        for (name, color) in standardTags {
            let on = urls.allSatisfy { FileOps.readTags($0).contains(name) }
            let b = BlockButton(frame: NSRect(x: x, y: 4, width: 18, height: 18)) { app.toggleTag(name, urls); menu.cancelTracking() }
            b.isBordered = false; b.title = ""; b.toolTip = name
            b.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
                if on { NSColor.white.setStroke(); let p = NSBezierPath(); p.lineWidth = 1.8; p.move(to: NSPoint(x: 5.5, y: 9)); p.line(to: NSPoint(x: 8, y: 6.5)); p.line(to: NSPoint(x: 12.5, y: 11.5)); p.stroke() }
                return true
            }
            addSubview(b); x += 27
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
final class BlockButton: NSButton {
    var block: () -> Void
    init(frame: NSRect, _ block: @escaping () -> Void) { self.block = block; super.init(frame: frame); target = self; action = #selector(fire) }
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { block() }
}

func fillMenu(_ menu: NSMenu, _ entries: [MEntry], app: AppState) {
    menu.removeAllItems(); menu.autoenablesItems = false
    for e in entries {
        switch e {
        case .sep: if let l = menu.items.last, !l.isSeparatorItem { menu.addItem(.separator()) }
        case .item(let t, let img, let checked, let enabled, let action):
            let i = BlockMenuItem(t, action); i.image = img; i.state = checked ? .on : .off; i.isEnabled = enabled; menu.addItem(i)
        case .sub(let t, let children):
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); let s = NSMenu(); fillMenu(s, children, app: app); i.submenu = s; menu.addItem(i)
        case .share(let urls):
            let i = NSSharingServicePicker(items: urls).standardShareMenuItem; i.title = "共享…"; menu.addItem(i)
        case .tagRow(let urls):
            let i = NSMenuItem(); i.view = TagRowView(urls: urls, app: app, menu: menu); menu.addItem(i)
        }
    }
    if let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }
}

// MARK: SwiftUI renderer
struct SpecMenu: View {
    let entries: [MEntry]
    let app: AppState
    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in row(e) }
    }
    func row(_ e: MEntry) -> AnyView {
        switch e {
        case .sep: return AnyView(Divider())
        case .item(let t, _, let checked, let enabled, let action):
            return AnyView(Button((checked ? "✓ " : "") + t, action: action).disabled(!enabled))
        case .sub(let t, let children): return AnyView(Menu(t) { SpecMenu(entries: children, app: app) })
        case .share(let urls): return AnyView(ShareLink(items: urls) { Text("共享…") })
        case .tagRow(let urls):
            return AnyView(ForEach(standardTags, id: \.0) { name, color in
                let on = urls.allSatisfy { FileOps.readTags($0).contains(name) }
                Button { app.toggleTag(name, urls) } label: { Label { Text((on ? "✓ " : "") + name) } icon: { Image(nsImage: dotImage(color)) } }
            })
        }
    }
}

// MARK: inline rename field for SwiftUI views (图标 / 分栏)
func baseNameRange(_ name: String, isDir: Bool) -> NSRange {
    let ns = name as NSString, ext = ns.pathExtension
    if isDir || ext.isEmpty || ns.deletingPathExtension.isEmpty { return NSRange(location: 0, length: ns.length) }
    return NSRange(location: 0, length: ns.length - (ext as NSString).length - 1)
}
/// 就地重命名的文本框：一放进窗口就成为第一响应者，并选中不含扩展名的部分（访达行为）
final class InlineTF: NSTextField {
    var selectRange = NSRange(location: 0, length: 0)
    var focused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !focused else { return }
        for d in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let s = self, let w = s.window, !s.focused || s.currentEditor() == nil else { return }
                if w.makeFirstResponder(s) { s.focused = true; s.currentEditor()?.selectedRange = s.selectRange }
            }
        }
    }
}
struct InlineNameField: NSViewRepresentable {
    let url: URL, isDir: Bool, app: AppState
    var fontSize: CGFloat = 11, center = true
    func makeCoordinator() -> C { C(url: url, app: app) }
    func makeNSView(context: Context) -> NSTextField {
        let tf = InlineTF(string: url.lastPathComponent)
        tf.delegate = context.coordinator; tf.font = .systemFont(ofSize: fontSize); tf.alignment = center ? .center : .left
        tf.isBordered = true; tf.focusRingType = .exterior; tf.lineBreakMode = .byTruncatingMiddle; tf.cell?.isScrollable = true
        tf.selectRange = baseNameRange(url.lastPathComponent, isDir: isDir)
        return tf
    }
    func updateNSView(_ v: NSTextField, context: Context) {}
    final class C: NSObject, NSTextFieldDelegate {
        let url: URL, app: AppState; var done = false
        init(url: URL, app: AppState) { self.url = url; self.app = app }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) { done = true; app.inlineRename = nil; app.focusActiveTable(); return true }
            return false
        }
        func controlTextDidEndEditing(_ n: Notification) {
            guard !done, let tf = n.object as? NSTextField else { return }
            done = true; let name = tf.stringValue
            app.inlineRename = nil; app.rename(url, to: name); app.focusActiveTable()
        }
    }
}

/// 右键先选中被点的项目（访达行为）。每个项目背后放一个不接收事件的标记视图，
/// 右键事件在派发前（本地监听器里）找到鼠标下的项目并选中它，然后菜单才弹出。
final class ItemMarker: NSView {
    var url: URL?
    var bg = false
    /// 路径栏上的一段（右键弹出「拷贝路径」等菜单）
    var seg = false
    weak var tab: TabModel?
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}
struct ItemMarkerView: NSViewRepresentable {
    let url: URL, tab: TabModel
    var bg = false
    var seg = false
    func makeNSView(context: Context) -> ItemMarker { let v = ItemMarker(); v.url = url; v.tab = tab; v.bg = bg; v.seg = seg; RightClick.markers.add(v); return v }
    func updateNSView(_ v: ItemMarker, context: Context) { v.url = url; v.tab = tab; v.bg = bg; v.seg = seg }
}

/// 分栏 / 画廊视图（SwiftUI）里的拖动：SwiftUI 的 .onDrag 每次只能拖一个项目，
/// 所以多选后拖动只会移动一个文件。这里改为在事件监听里识别「按下 → 移动超过 4 点」，
/// 用 AppKit 拖动会话把所有选中的项目一起拖出（访达行为：拖未选中的项目只拖它自己）。
/// 只在按下鼠标后才判断，鼠标悬停不做任何事。
enum MultiDrag {
    struct Pending { let url: URL; weak var tab: TabModel?; let at: NSPoint; weak var view: NSView? }
    static var pending: Pending?
    static let source = MultiDragSource()
    /// 鼠标下的 SwiftUI 项目标记（列表 / 图标视图、文本框里不算）
    static func marker(at p: NSPoint, in w: NSWindow) -> ItemMarker? {
        guard let root = w.contentView?.superview else { return nil }
        var h = root.hitTest(root.convert(p, from: root.superview))
        while let v = h { if v is NSTableView || v is NSCollectionView || v is NSTextView || v is NSControl { return nil }; h = v.superview }
        return RightClick.markers.allObjects.first { m in
            m.window === w && !m.bg && !m.seg && m.url != nil && m.tab != nil && !m.isHiddenOrHasHiddenAncestor && visibleFrame(m).contains(p)
        }
    }
    /// 标记在窗口里实际可见的区域：自身范围再裁掉所在滚动视图之外的部分
    /// （SwiftUI 承载的视图 visibleRect 不可靠，会比自身还大，不能直接用）
    static func visibleFrame(_ m: NSView) -> NSRect {
        var r = m.convert(m.bounds, to: nil)
        var s = m.enclosingScrollView
        while let sv = s { r = r.intersection(sv.convert(sv.bounds, to: nil)); s = sv.enclosingScrollView }
        return r
    }
    static func down(_ e: NSEvent) {
        pending = nil
        guard let w = e.window, let m = marker(at: e.locationInWindow, in: w), let u = m.url else { return }
        pending = Pending(url: u, tab: m.tab, at: e.locationInWindow, view: m)
    }
    /// 返回 true 表示已开始拖动（事件被消费）
    static func dragged(_ e: NSEvent) -> Bool {
        guard let p = pending, let v = p.view, let t = p.tab, e.window === v.window else { return false }
        guard hypot(e.locationInWindow.x - p.at.x, e.locationInWindow.y - p.at.y) > 4 else { return false }
        pending = nil
        let urls = urlsToDrag(p.url, tab: t)
        // 列表里的项目已经不在磁盘上（被别处移走）：不拖，刷新这一栏（截掉不存在的栏）
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { NSSound.beep(); t.reload(); return true }
        if !t.selection.contains(p.url) { t.selection = [p.url]; t.anchor = p.url }
        let local = v.convert(p.at, from: nil)
        let items = ShelfDragView.draggingItems(urls, from: v)
        for it in items { var f = it.draggingFrame; f.origin.x += local.x - 16; f.origin.y += local.y - 16; it.draggingFrame = f }
        v.beginDraggingSession(with: items, event: e, source: source)
        return true
    }
    /// 拖动选中的项目时拖动全部选中项目，否则只拖被按住的那一个
    static func urlsToDrag(_ u: URL, tab: TabModel) -> [URL] { withoutNested(itemMenuURLs(tab, u)) }
}
final class MultiDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link, .generic] }
}

/// 路径栏某一段的右键菜单（访达：拷贝路径、在新标签页中打开、在访达中显示）
func pathSegmentSpec(app: AppState, pane i: Int, url u: URL) -> [MEntry] {
    let name = u.path == "/" ? (volumeName(u) ?? "/") : u.lastPathComponent
    return [
        .item("打开", sym("folder"), false, true) { app.focusPane(i); app.panes[i].tab.navigate(u) },
        .item("在新标签页中打开", sym("plus.square.on.square"), false, true) { app.focusPane(i); app.newTab(); app.panes[i].tab.navigate(u) },
        .sep,
        .item("拷贝路径", sym("doc.on.doc"), false, true) { copyPaths([u]) },
        .item("拷贝“\(name)”的路径名称", sym("doc.on.clipboard"), false, true) { copyPaths([u]) },
        .sep,
        .item("在访达中显示", sym("magnifyingglass"), false, true) { NSWorkspace.shared.activateFileViewerSelecting([u]) },
    ]
}
func volumeName(_ u: URL) -> String? { (try? u.resourceValues(forKeys: [.volumeNameKey]))?.volumeName }
/// 全局事件监听：
/// 1. 活动栏：在某一栏里按下鼠标（左键 / 右键）时切换到那一栏；悬停、滚动、拖动经过、按键都不切换（访达）
/// 2. 分栏 / 画廊视图的右键菜单：在右键时才构建（AppKit 菜单），不在每次界面刷新时预先计算
enum RightClick {
    static var monitor: Any?
    static weak var app: AppState?
    static let markers = NSHashTable<ItemMarker>.weakObjects()
    static var lastMenu: NSMenu?
    static func install(_ a: AppState? = nil) {
        if let a = a { app = a }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .scrollWheel, .keyDown]) { e in
            guard let a = app else { return e }
            if let w = e.window, !w.acceptsMouseMovedEvents, w.toolbar != nil { w.acceptsMouseMovedEvents = true }
            switch e.type {
            case .mouseMoved, .scrollWheel: return e   // 访达：悬停、滚动不切换活动栏
            case .leftMouseDragged: return MultiDrag.dragged(e) ? nil : e
            case .leftMouseUp: MultiDrag.pending = nil; return e
            case .keyDown:
                // 快捷键作用于最后点按的那一栏（活动栏），与鼠标在哪无关
                // 切换显示方式、关闭重命名框等之后，焦点可能短暂落在窗口本身：快捷键仍然作用于当前栏（访达的快捷键总是有效）
                if let w = e.window, w.toolbar != nil, w.attachedSheet == nil, a.active < a.controllers.count,
                   w.firstResponder === w || w.firstResponder == nil || strayResponder(w.firstResponder, mode: a.activeTab.viewMode) {
                    let c = a.controllers[a.active]
                    let handled = e.modifierFlags.contains(.command) ? c.handleKeyEquivalent(e) : c.handleKeyDown(e, isTable: false)
                    if handled { DispatchQueue.main.async { a.focusActiveTable() }; return nil }
                }
                return e
            default:
                if e.type == .leftMouseDown {
                    MultiDrag.pending = nil
                    if !a.palette.visible, !e.modifierFlags.contains(.control) { PaneFocus.follow(e, app: a); MultiDrag.down(e) }
                }
                // 命令面板打开时：右键 / 点按交给面板本身，不弹出底下文件栏的菜单
                if a.palette.visible { return e }
                guard e.type == .rightMouseDown || e.modifierFlags.contains(.control) else { return e }
                PaneFocus.follow(e, app: a)
                return contextMenu(e, app: a) ? nil : e
            }
        }
    }
    /// 分栏 / 画廊视图（SwiftUI）里，点按后焦点可能落在 SwiftUI 的承载视图上，按键到不了这一栏：
    /// 这种情况也交给当前栏处理（文本框、列表、图标视图、按钮等自己处理按键的不算）
    static func strayResponder(_ r: NSResponder?, mode: ViewMode) -> Bool {
        guard mode == .column || mode == .gallery, let v = r as? NSView else { return false }
        return !(v is NSText || v is NSTableView || v is NSCollectionView || v is FBKeyView || v is NSControl)
    }
    /// 鼠标下（画廊、分栏等 SwiftUI 视图背后）负责这一栏的 FBKeyView
    static func keyViewUnder(_ root: NSView, _ p: NSPoint) -> FBKeyView? {
        var h = root.hitTest(root.convert(p, from: root.superview))
        while let v = h { if let k = v as? FBKeyView { return k }; h = v.superview }
        return nil
    }
    /// 返回 true 表示已经弹出了菜单（事件被消费）
    static func contextMenu(_ e: NSEvent, app: AppState) -> Bool {
        guard let w = e.window, let root = w.contentView?.superview else { return false }
        let p = e.locationInWindow
        // 列表 / 图标视图是 AppKit 视图，自己处理右键
        var h = root.hitTest(root.convert(p, from: root.superview))
        while let v = h { if v is NSTableView || v is NSCollectionView || (v as? NSTextView)?.isFieldEditor == true { return false }; h = v.superview }
        let live = markers.allObjects.filter { $0.window === w && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(p) }
        func paneOf(_ t: TabModel?) -> Int? { app.panes.firstIndex { $0.tab === t } }
        func paneOfSeg(_ t: TabModel?) -> Int? { paneOf(t) }
        if let m = live.first(where: { $0.seg }), let u = m.url, let i = paneOfSeg(m.tab) {
            let menu = NSMenu(); fillMenu(menu, pathSegmentSpec(app: app, pane: i, url: u), app: app)
            lastMenu = menu
            let view = app.responders[i].v ?? root
            DispatchQueue.main.async { NSMenu.popUpContextMenu(menu, with: e, for: view) }
            return true
        }
        var pane: Int?, urls: [URL] = [], bgDir: URL?
        if let m = live.first(where: { !$0.bg && !$0.seg }), let u = m.url, let t = m.tab, let i = paneOf(t) {
            if !t.selection.contains(u) { t.selection = [u]; t.anchor = u }
            pane = i; urls = itemMenuURLs(t, u)
        } else if let m = live.first(where: { $0.bg && !$0.seg }), let t = m.tab, let i = paneOf(t) {
            pane = i; bgDir = m.url
        } else if let k = keyViewUnder(root, p) {
            pane = k.pane
        } else if let i = PaneFocus.pane(at: p, in: w, app: app), app.responders[i].v is FBKeyView,
                  let k = app.responders[i].v, k.convert(k.bounds, to: nil).contains(p) {
            pane = i
        }
        guard let i = pane else { return false }
        app.focusPane(i)
        let tab = app.panes[i].tab
        let m = NSMenu(); fillMenu(m, contextSpec(app: app, tab: tab, pane: i, urls: urls, bgDir: bgDir), app: app)
        lastMenu = m
        let view = app.responders[i].v ?? root
        DispatchQueue.main.async { NSMenu.popUpContextMenu(m, with: e, for: view) }
        return true
    }
}
func itemMenuURLs(_ tab: TabModel, _ u: URL) -> [URL] { tab.selection.contains(u) ? tab.selectedURLs : [u] }

struct ViewOptionsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("显示选项").font(.headline)
            HStack { Text("图标大小"); Slider(value: $app.iconSize, in: 32...256, step: 8); Text("\(Int(app.iconSize))").monospacedDigit().frame(width: 34) }
            Toggle("显示预览栏", isOn: $app.showPreview)
            Toggle("显示隐藏文件", isOn: $app.showHidden)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 360)
    }
}

func specTitles(_ es: [MEntry]) -> [String] {
    es.map { e in
        switch e {
        case .item(let t, _, _, let en, _): return en ? t : "(\(t))"
        case .sep: return "—"
        case .sub(let t, _): return t + "▸"
        case .share: return "共享…"
        case .tagRow: return "标签"
        }
    }
}
