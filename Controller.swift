import SwiftUI
import AppKit
import Quartz

final class BlockMenuItem: NSMenuItem {
    var block: () -> Void
    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { block() }
}

/// Per-pane controller: keyboard handling, Quick Look and the AppKit context menu, shared by every view mode.
final class PaneController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    unowned let app: AppState
    let pane: Int
    var qlURLs: [URL] = []
    var iconColumns = 4
    var qlOpen = false
    init(app: AppState, pane: Int) { self.app = app; self.pane = pane }
    var tab: TabModel { app.panes[pane].tab }

    func visualOrder() -> [URL] {
        let t = tab
        if t.viewMode == .icon && !t.isGlobalSearch { return t.groupedOrder }
        return t.display.map { $0.url }
    }
    func openSelection() {
        let s = tab.selectedURLs
        guard !s.isEmpty else { NSSound.beep(); return }
        app.openURLs(s, in: tab)
    }
    func renameSelection() {
        let s = tab.selectedURLs
        guard s.count == 1 else { NSSound.beep(); return }
        app.beginRename(s[0])
    }
    func moveSelection(_ delta: Int, extend: Bool) {
        let order = visualOrder()
        guard !order.isEmpty else { return }
        let cur = tab.anchor.flatMap { order.firstIndex(of: $0) } ?? tab.selectedURLs.last.flatMap { order.firstIndex(of: $0) }
        let next = cur.map { max(0, min(order.count - 1, $0 + delta)) } ?? 0
        let u = order[next]
        if extend { tab.selection.insert(u) } else { tab.selection = [u] }
        tab.anchor = u
    }

    // MARK: keys
    func handleKeyDown(_ e: NSEvent, isTable: Bool) -> Bool {
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 49: quickLook(); return true
        case 36, 76: if f.contains(.command) { openSelection() } else { renameSelection() }; return true
        case 48: app.switchPane(); return true
        case 53:
            if FolderPeek.shared.isVisible { FolderPeek.shared.close(); return true }
            if tab.searchActive { tab.clearSearch(); return true }; return false
        case 51, 117: if f.contains(.command) { app.trash(tab.selectedURLs); return true }; return false
        case 125: if f.contains(.command) { openSelection(); return true }
        case 126: if f.contains(.command) { tab.goUp(); return true }
        default: break
        }
        // 分栏视图：↑↓ 在当前栏内移动，→ 进入文件夹（下一栏），← 回到上一栏（访达）
        if tab.viewMode == .column, !tab.isGlobalSearch, f.subtracting(.shift).isEmpty, columnKey(e, extend: f.contains(.shift)) { return true }
        // 键入名称选择（列表视图用 NSTableView 自带的）
        if tab.viewMode != .list, f.subtracting(.shift).isEmpty, typeSelect(e) { return true }
        guard !isTable, f.subtracting(.shift).isEmpty, tab.viewMode != .column else { return false }
        let ext = f.contains(.shift)
        let cols = tab.viewMode == .gallery ? 1 : max(1, iconColumns)
        switch e.keyCode {
        case 123: moveSelection(-1, extend: ext); return true
        case 124: moveSelection(1, extend: ext); return true
        case 126: moveSelection(-cols, extend: ext); return true
        case 125: moveSelection(cols, extend: ext); return true
        default: return false
        }
    }
    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        // 访达：⌘C 之后按 ⌥⌘V = 移动到这里
        if f == [.command, .option], e.charactersIgnoringModifiers?.lowercased() == "v" { app.paste(into: pasteDir, forceMove: true); return true }
        guard f == .command else { return false }
        switch e.keyCode {
        case 51: app.trash(tab.selectedURLs); return true
        case 125: openSelection(); return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "c": app.copyToClipboard(tab.selectedURLs, cut: false); return true
        case "x": app.copyToClipboard(tab.selectedURLs, cut: true); return true
        case "v": app.paste(into: pasteDir); return true
        case "z": app.undo(); return true
        case "d": app.duplicate(tab.selectedURLs); return true
        case "a": tab.selection = Set(tab.display.map { $0.url }); return true
        default: return false
        }
    }

    /// 粘贴目标：当前文件夹（分栏视图里是最右侧打开的文件夹）
    var pasteDir: URL { tab.viewMode == .column && !tab.isGlobalSearch ? (tab.columnChain.last ?? tab.path) : tab.path }

    // MARK: column view keyboard
    var columnDirs: [URL] { [tab.path] + tab.columnChain }
    func columnItems(_ k: Int) -> [FileItem] {
        let dirs = columnDirs
        guard k >= 0, k < dirs.count else { return [] }
        return k == 0 ? tab.items : (tab.columnLoader?.lists[dirs[k].path] ?? [])
    }
    /// 当前选择（锚点）所在的栏；没有选择时是最右边那一栏
    func focusedColumn() -> Int {
        let dirs = columnDirs
        if let a = tab.anchor ?? tab.selectedURLs.last, let k = dirs.firstIndex(where: { $0.standardizedFileURL.path == a.deletingLastPathComponent().standardizedFileURL.path }) { return k }
        return dirs.count - 1
    }
    /// 和点按某一栏里的项目一样：截断右边的栏；选中文件夹时打开它的下一栏
    func columnSelect(_ u: URL, at k: Int) {
        tab.columnChain = Array(tab.columnChain.prefix(k))
        let it = columnItems(k).first { $0.url == u } ?? makeItem(u)
        if it.isFolderLike { tab.columnChain.append(u); tab.columnLoader?.load(u, hidden: app.showHidden, sortKey: tab.sortKey, asc: tab.asc) }
        tab.selection = [u]; tab.anchor = u
    }
    func columnKey(_ e: NSEvent, extend: Bool) -> Bool {
        let k = focusedColumn(), items = columnItems(k)
        let cur = (tab.anchor ?? tab.selectedURLs.last).flatMap { a in items.firstIndex { $0.url == a } }
        switch e.keyCode {
        case 125, 126:
            guard !items.isEmpty else { return true }
            let d = e.keyCode == 125 ? 1 : -1
            let n = cur.map { max(0, min(items.count - 1, $0 + d)) } ?? (d > 0 ? 0 : items.count - 1)
            let u = items[n].url
            if extend { tab.selection.insert(u); tab.anchor = u } else { columnSelect(u, at: k) }
            return true
        case 124:
            guard let c = cur, items[c].isFolderLike else { return true }
            if tab.columnChain.count <= k || tab.columnChain[k] != items[c].url { columnSelect(items[c].url, at: k) }
            let next = columnItems(k + 1)
            if let f = next.first { columnSelect(f.url, at: k + 1) }
            else if tab.columnLoader?.lists[items[c].url.path] == nil {
                // 下一栏还没读完：读完后再选中第一项（一次性回调，不轮询）
                let u = items[c].url
                tab.columnLoader?.whenLoaded(u) { [weak self] list in
                    guard let self = self, self.tab.anchor == u, let f = list.first else { return }
                    self.columnSelect(f.url, at: k + 1)
                }
            }
            return true
        case 123:
            guard k > 0 else { return true }
            let parent = columnDirs[k]
            tab.columnChain = Array(tab.columnChain.prefix(k))
            tab.selection = [parent]; tab.anchor = parent
            return true
        default: return false
        }
    }
    // MARK: type to select（分栏 / 图标 / 画廊视图）
    var typeBuf = "", typeAt: TimeInterval = 0
    func typeSelect(_ e: NSEvent) -> Bool {
        guard let ch = e.characters, !ch.isEmpty, e.keyCode != 49,
              ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }) else { return false }
        if e.timestamp - typeAt > 1.0 { typeBuf = "" }
        typeAt = e.timestamp; typeBuf += ch.lowercased()
        let col = tab.viewMode == .column && !tab.isGlobalSearch
        let k = col ? focusedColumn() : 0
        let names: [(URL, String)] = col ? columnItems(k).map { ($0.url, $0.name) } : tab.display.map { ($0.url, $0.name) }
        let order = col ? names.map { $0.0 } : visualOrder()
        let byURL = Dictionary(names.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        guard let hit = order.first(where: { (byURL[$0] ?? "").lowercased().hasPrefix(typeBuf) }) else { return true }
        if col { columnSelect(hit, at: k) } else { tab.selection = [hit]; tab.anchor = hit }
        return true
    }

    // MARK: Quick Look
    func quickLook(_ urls: [URL]? = nil) {
        // 文件夹（包括空文件夹）：显示文件夹的快速查看（图标、名称、项目数、修改时间、空间分析按钮）
        if urls == nil, FolderPeek.shared.isVisible { FolderPeek.shared.close(); return }
        let target = urls ?? tab.selectedURLs
        if target.count == 1, makeItem(target[0]).isFolderLike {
            if !TestEnv.active, QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible { p.orderOut(nil) }
            FolderPeek.shared.show(target[0], app: app); return
        }
        if FolderPeek.shared.isVisible { FolderPeek.shared.close() }
        if TestEnv.active { if urls == nil && !qlURLs.isEmpty && qlOpen { qlOpen = false; return }; qlURLs = urls ?? tab.selectedURLs; qlOpen = !qlURLs.isEmpty; return }
        guard let p = QLPreviewPanel.shared() else { return }
        if urls == nil && QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.orderOut(nil); return }
        qlURLs = urls ?? tab.selectedURLs
        guard !qlURLs.isEmpty else { NSSound.beep(); return }
        if let v = app.responders[pane].v { v.window?.makeFirstResponder(v) }
        if TestEnv.active { return }   // 测试时不在屏幕上弹出快速查看窗口
        p.dataSource = self; p.delegate = self
        p.makeKeyAndOrderFront(nil); p.reloadData()
    }
    func refreshQL() {
        if FolderPeek.shared.isVisible, app.active == pane {
            let s = tab.selectedURLs
            if s.count == 1, makeItem(s[0]).isFolderLike { if s[0] != FolderPeek.shared.url { FolderPeek.shared.show(s[0], app: app) } }
            else if !s.isEmpty { FolderPeek.shared.close(); quickLook(s) }
            return
        }
        guard QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible, (p.dataSource as AnyObject?) === self else { return }
        let s = tab.selectedURLs
        guard !s.isEmpty else { return }
        qlURLs = s; p.reloadData()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { qlURLs[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode), let v = app.responders[pane].v { v.keyDown(with: event); return true }
        return false
    }

    // MARK: AppKit context menu (list view)
    func buildMenu(_ menu: NSMenu, urls: [URL]) { fillMenu(menu, contextSpec(app: app, tab: tab, pane: pane, urls: urls), app: app) }
}

func dotImage(_ c: NSColor?) -> NSImage {
    NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
        if let c = c { c.setFill(); p.fill() } else { NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1.2; p.stroke() }
        return true
    }
}
func tagDots(_ tags: [String]) -> NSAttributedString {
    let s = NSMutableAttributedString()
    for t in tags.prefix(5) {
        s.append(NSAttributedString(string: tagColor(t) == nil ? "○" : "●", attributes: [.foregroundColor: tagColor(t) ?? NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 10)]))
    }
    return s
}

/// Invisible first responder for icon / column / gallery views so keyboard shortcuts and Quick Look work there too.
final class FBKeyView: NSView {
    weak var app: AppState?
    var pane = 0
    var ctrl: PaneController? { app.flatMap { pane < $0.controllers.count ? $0.controllers[pane] : nil } }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let a = app, a.active != pane { let p = pane; DispatchQueue.main.async { a.active = p } }
        return true
    }
    override func keyDown(with e: NSEvent) { if ctrl?.handleKeyDown(e, isTable: false) != true { super.keyDown(with: e) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, let c = ctrl, c.handleKeyEquivalent(e) { return true }
        return super.performKeyEquivalent(with: e)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = ctrl; panel.delegate = ctrl }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { }
}
struct KeyCatcher: NSViewRepresentable {
    let app: AppState, pane: Int
    func makeNSView(context: Context) -> FBKeyView {
        let v = FBKeyView(); v.app = app; v.pane = pane; app.responders[pane].v = v
        DispatchQueue.main.async { if app.active == pane { v.window?.makeFirstResponder(v) } }
        return v
    }
    func updateNSView(_ v: FBKeyView, context: Context) { v.pane = pane; app.responders[pane].v = v }
}
