import SwiftUI
import AppKit
import Quartz

final class FBTableView: NSTableView {
    weak var coord: FileTable.Coordinator?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let c = coord, c.app.active != c.pane { DispatchQueue.main.async { c.app.active = c.pane } }
        return ok
    }
    override func keyDown(with e: NSEvent) {
        if let c = coord, c.ctrl.handleKeyDown(e, isTable: true) { return }
        super.keyDown(with: e)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, let c = coord, c.ctrl.handleKeyEquivalent(e) { return true }
        return super.performKeyEquivalent(with: e)
    }
    /// 和访达一样：在列表空白处（最后一行下面）按下拖动 = 框选。NSTableView 自带的行为在空白处只会清除选择。
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard row(at: p) < 0, e.clickCount == 1, let w = window else { super.mouseDown(with: e); return }
        w.makeFirstResponder(self)
        let f = e.modifierFlags
        let toggle = f.contains(.command), extend = f.contains(.shift)
        let base = selectedRowIndexes
        if !toggle && !extend { selectRowIndexes([], byExtendingSelection: false) }
        let band = MarqueeView(frame: NSRect(origin: p, size: .zero)); addSubview(band)
        defer { band.removeFromSuperview() }
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(ev.locationInWindow, from: nil)
            let r = NSRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
            band.frame = r
            if ev.type == .leftMouseDragged { autoscroll(with: ev) }
            var hit = IndexSet()
            // 纯竖直拖动时矩形宽度为 0，也要算作框住了经过的行
            let rr = rows(in: NSRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, 1)))
            if rr.length > 0 { for i in rr.location..<(rr.location + rr.length) where coord?.item(i) != nil { hit.insert(i) } }
            let sel: IndexSet = toggle ? base.symmetricDifference(hit) : (extend ? base.union(hit) : hit)
            if sel != selectedRowIndexes { selectRowIndexes(sel, byExtendingSelection: false) }
            if ev.type == .leftMouseUp { break }
        }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = coord?.ctrl; panel.delegate = coord?.ctrl }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { }
}

/// 框选矩形（和访达一样的半透明强调色）
final class MarqueeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// 列表单元格：直接绘制图标和文字（不用 NSTextField / NSImageView 子视图）。
/// 大目录批量移入、移出时要一次创建几十个单元格，子视图方案每格要建 2~3 个控件并做布局，绘制方案几乎没有开销。
/// 只有就地重命名时才临时放一个可编辑的 NSTextField。
final class DrawCell: NSTableCellView {
    // 用和 NSTextField 标签相同的 NSTextFieldCell 绘制：字体、基线、截断、选中时反白都和原生标签完全一致，但不需要子视图
    let tcell: NSTextFieldCell = { let c = NSTextFieldCell(textCell: ""); c.isBordered = false; c.drawsBackground = false; c.isEditable = false; c.font = .systemFont(ofSize: NSFont.systemFontSize); c.textColor = .labelColor; c.truncatesLastVisibleLine = true; return c }()
    let tagCell: NSTextFieldCell = { let c = NSTextFieldCell(textCell: ""); c.isBordered = false; c.drawsBackground = false; c.isEditable = false; return c }()
    var text = "" { didSet { if text != oldValue { tcell.stringValue = text; needsDisplay = true; setAccessibilityLabel(text) } } }
    var icon: NSImage? { didSet { if icon !== oldValue { needsDisplay = true } } }
    var tags = NSAttributedString() { didSet { if tags != oldValue { tagCell.attributedStringValue = tags; needsDisplay = true } } }
    var secondary = false { didSet { tcell.textColor = secondary ? .secondaryLabelColor : .labelColor } }
    var mono = false { didSet { tcell.font = mono ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize) } }
    var rightAlign = false { didSet { tcell.alignment = rightAlign ? .right : .natural } }
    var middleTrunc = false { didSet { tcell.lineBreakMode = middleTrunc ? .byTruncatingMiddle : .byTruncatingTail } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { if backgroundStyle != oldValue { tcell.backgroundStyle = backgroundStyle; tagCell.backgroundStyle = backgroundStyle; needsDisplay = true } } }
    var editor: NSTextField?
    var font: NSFont { tcell.font ?? .systemFont(ofSize: NSFont.systemFontSize) }
    var isName = false
    var textX: CGFloat { isName ? 24 : 2 }
    func textRect() -> NSRect {
        let h = ceil(tcell.cellSize.height)
        // NSTextFieldCell 直接绘制时比标签控件多 2pt 内边距：两侧各放宽 2pt，文字位置与原来的标签逐像素一致
        return NSRect(x: textX - 2, y: floor((bounds.height - h) / 2), width: max(0, bounds.width - textX + 2), height: h)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let ic = icon {
            ic.draw(in: NSRect(x: 2, y: floor((bounds.height - 16) / 2), width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard editor == nil else { return }
        var r = textRect()
        if tags.length > 0 {
            let tw = ceil(tagCell.cellSize.width)
            let nw = min(ceil(tcell.cellSize.width), max(0, r.width - tw - 4))
            tagCell.draw(withFrame: NSRect(x: r.minX + nw + 4, y: r.minY, width: tw, height: r.height), in: self)
            r.size.width = nw
        }
        tcell.draw(withFrame: r, in: self)
    }
    /// 就地重命名：放一个真正的文本框在文字的位置
    func beginEditing() -> NSTextField {
        if let e = editor { return e }
        let tf = NSTextField(string: text)
        tf.font = font; tf.isBordered = true; tf.drawsBackground = true; tf.backgroundColor = .textBackgroundColor
        tf.lineBreakMode = .byClipping; tf.usesSingleLineMode = true; tf.cell?.isScrollable = true
        var r = textRect(); r.origin.x -= 2; r.size.width += 2; r.size.height = max(r.height, 20); r.origin.y = floor((bounds.height - r.height) / 2)
        tf.frame = r; tf.autoresizingMask = [.width]
        addSubview(tf); editor = tf; textField = tf; needsDisplay = true
        return tf
    }
    func endEditing() {
        editor?.removeFromSuperview(); editor = nil; textField = nil; needsDisplay = true
    }
}

struct FileTable: NSViewRepresentable {
    let tab: TabModel, app: AppState, paneIndex: Int, version: Int, selection: Set<URL>, renaming: URL?

    func makeCoordinator() -> Coordinator { Coordinator(app: app, tab: tab, pane: paneIndex) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = FBTableView(); tv.coord = c; c.table = tv
        tv.style = .fullWidth; tv.usesAlternatingRowBackgroundColors = true; tv.allowsMultipleSelection = true
        tv.rowHeight = 22; tv.intercellSpacing = NSSize(width: 6, height: 2); tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsTypeSelect = true
        for (id, title, w) in [("name", "名称", 280.0), ("date", "修改日期", 135.0), ("size", "大小", 80.0), ("kind", "种类", 120.0), ("path", "位置", 260.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = w; col.minWidth = id == "name" ? 120 : 50
            if id != "path" { col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            if id == "size" { col.headerCell.alignment = .right }
            tv.addTableColumn(col)
        }
        // 列宽不再自动保存：由 layoutColumns 按可用宽度分配（和访达一样，名称列吸收多余宽度，窄时依次隐藏 种类 → 大小 → 修改日期）
        let hm = NSMenu(); hm.delegate = c; tv.headerView?.menu = hm; c.headerMenu = hm
        tv.dataSource = c; tv.delegate = c
        tv.target = c; tv.doubleAction = #selector(Coordinator.doubleClick(_:))
        let menu = NSMenu(); menu.delegate = c; tv.menu = menu
        tv.registerForDraggedTypes([.fileURL])
        tv.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        tv.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        let sv = NSScrollView(); sv.documentView = tv; sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true; sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.clipResized), name: NSView.frameDidChangeNotification, object: sv.contentView)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.columnResized(_:)), name: NSTableView.columnDidResizeNotification, object: tv)
        app.responders[paneIndex].v = tv
        c.sync()
        DispatchQueue.main.async { if app.active == paneIndex { tv.window?.makeFirstResponder(tv) } }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.pane = paneIndex
        if c.tab !== tab { c.tab = tab; c.lastVersion = -1 }
        if let tv = c.table { app.responders[paneIndex].v = tv }
        c.sync()
    }

    enum Row { case header(String, Int), item(FileItem) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        let app: AppState; var tab: TabModel; var pane: Int
        var rows: [Row] = []; var lastVersion = -1; var suppress = false
        /// 表格自己刚写回的选中集合：SwiftUI 回调 updateNSView 时不必再逐项比较一遍
        var pushedSelection: Set<URL> = []
        weak var table: FBTableView?
        var ctrl: PaneController { app.controllers[pane] }

        init(app: AppState, tab: TabModel, pane: Int) {
            self.app = app; self.tab = tab; self.pane = pane
            super.init()
            NotificationCenter.default.addObserver(forName: .fbColumnsChanged, object: nil, queue: .main) { [weak self] _ in self?.layoutColumns() }
        }

        // MARK: 列布局
        weak var headerMenu: NSMenu?
        var laying = false
        static let optional: [(String, String, CGFloat)] = [("date", "修改日期", 140), ("size", "大小", 72), ("kind", "种类", 120)]
        static var enabledCols: Set<String> {
            get { Set(UserDefaults.standard.stringArray(forKey: "listColumns") ?? ["date", "size", "kind"]) }
            set { UserDefaults.standard.set(Array(newValue), forKey: "listColumns") }
        }
        static func preferredWidth(_ id: String, _ def: CGFloat) -> CGFloat {
            let w = UserDefaults.standard.double(forKey: "listColW_\(id)"); return w > 30 ? CGFloat(w) : def
        }
        @objc func clipResized() { layoutColumns() }
        @objc func columnResized(_ n: Notification) {
            // 用户拖动列宽：记住非名称列的宽度
            guard !laying, let tv = table, let hv = tv.headerView, hv.resizedColumn >= 0,
                  let col = (n.userInfo?["NSTableColumn"] as? NSTableColumn), col.identifier.rawValue != "name" else { return }
            UserDefaults.standard.set(Double(col.width), forKey: "listColW_\(col.identifier.rawValue)")
            DispatchQueue.main.async { self.layoutColumns() }
        }
        /// 纯函数：给定可用宽度，返回要显示的列和宽度
        static func plan(avail: CGFloat, enabled: Set<String>, search: Bool, spacing: CGFloat = 6) -> [(String, CGFloat)] {
            var cols: [(String, CGFloat)] = optional.filter { enabled.contains($0.0) }.map { ($0.0, preferredWidth($0.0, $0.2)) }
            if search { cols.append(("path", preferredWidth("path", 220))) }
            let minName: CGFloat = 160
            // 每列右侧都有一个列间距，再留一个间距的余量，保证最后一列完整显示、不出现横向滚动
            func used() -> CGFloat { cols.reduce(0) { $0 + $1.1 } + CGFloat(cols.count + 2) * spacing }
            // 太窄时先隐藏优先级低的列（位置 → 种类 → 大小 → 修改日期）
            let dropOrder = ["path", "kind", "size", "date"]
            for d in dropOrder where avail - used() < minName { cols.removeAll { $0.0 == d } }
            return [("name", max(minName, avail - used()))] + cols
        }
        func layoutColumns() {
            guard let tv = table, let sv = tv.enclosingScrollView else { return }
            let avail = sv.contentView.bounds.width
            guard avail > 50 else { return }
            laying = true; defer { laying = false }
            let p = Coordinator.plan(avail: avail, enabled: Coordinator.enabledCols, search: tab.isGlobalSearch, spacing: tv.intercellSpacing.width)
            let show = Dictionary(uniqueKeysWithValues: p.map { ($0.0, $0.1) })
            for col in tv.tableColumns {
                let id = col.identifier.rawValue
                if let w = show[id] { col.isHidden = false; if abs(col.width - w) > 0.5 { col.width = w } } else { col.isHidden = true }
            }
        }
        func menuForHeader(_ menu: NSMenu) {
            menu.removeAllItems()
            let on = Coordinator.enabledCols
            for (id, title, _) in Coordinator.optional {
                let it = NSMenuItem(title: title, action: #selector(toggleCol(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = id; it.state = on.contains(id) ? .on : .off
                menu.addItem(it)
            }
            menu.addItem(.separator())
            let r = NSMenuItem(title: "恢复默认列宽", action: #selector(resetCols), keyEquivalent: ""); r.target = self; menu.addItem(r)
        }
        @objc func toggleCol(_ s: NSMenuItem) {
            guard let id = s.representedObject as? String else { return }
            var e = Coordinator.enabledCols; if e.contains(id) { e.remove(id) } else { e.insert(id) }
            Coordinator.enabledCols = e
            NotificationCenter.default.post(name: .fbColumnsChanged, object: nil)
        }
        @objc func resetCols() {
            for (id, _, _) in Coordinator.optional { UserDefaults.standard.removeObject(forKey: "listColW_\(id)") }
            UserDefaults.standard.removeObject(forKey: "listColW_path")
            NotificationCenter.default.post(name: .fbColumnsChanged, object: nil)
        }

        func item(_ r: Int) -> FileItem? {
            guard r >= 0, r < rows.count, case .item(let it) = rows[r] else { return nil }
            return it
        }
        var selectedURLs: [URL] { table?.selectedRowIndexes.compactMap { item($0)?.url } ?? [] }

        func sync() {
            guard let tv = table else { return }
            if lastVersion != tab.version {
                // 正在就地重命名时不要刷新表格（reloadData 会结束编辑），改完名再刷新
                if editingURL != nil { return }
                lastVersion = tab.version
                let old = rows
                if tab.groupKey == .none || tab.isGlobalSearch { rows = tab.display.map { .item($0) } }
                else { rows = tab.groups.flatMap { g in [Row.header(g.0, g.1.count)] + g.1.map { Row.item($0) } } }
                layoutColumns()
                suppress = true
                let d = NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.asc)
                if tv.sortDescriptors.first != d { tv.sortDescriptors = [d] }
                if !applyIncremental(tv, old: old) { tv.reloadData() }
                suppress = false
                applySelection()
            } else if tab.selection != pushedSelection, Set(selectedURLs) != tab.selection { applySelection() }
            if app.inlineRename != nil && editingURL == nil { DispatchQueue.main.async { self.startInlineRename() } }
        }

        // MARK: 就地重命名（和访达一样：回车进入编辑，选中不含扩展名的部分；回车或点别处确认，Esc 取消）
        var editingURL: URL?
        var cancelled = false
        func startInlineRename() {
            if TestEnv.debug { print("DEBUG startInline u=\(String(describing: app.inlineRename?.path)) editing=\(String(describing: editingURL)) table=\(table != nil) rows=\(rows.compactMap { if case .item(let it) = $0 { return it.url.path } else { return nil } }.prefix(3))") }
            guard let u = app.inlineRename, editingURL == nil, let tv = table,
                  let row = rows.firstIndex(where: { if case .item(let it) = $0 { return samePath(it.url, u) }; return false }) else { return }
            let col = tv.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            guard col >= 0 else { return }
            tv.scrollRowToVisible(row)
            guard let cell = tv.view(atColumn: col, row: row, makeIfNecessary: true) as? DrawCell, let it = item(row) else { if TestEnv.debug { print("DEBUG no cell row=\(row)") }; return }
            if TestEnv.debug { print("DEBUG editing row=\(row) win=\(tv.window != nil)") }
            editingURL = u; cancelled = false
            let tf = cell.beginEditing()
            tf.delegate = self
            tv.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectedRange = baseNameRange(it.name, isDir: it.isDir)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)), let tf = control as? NSTextField, editingURL != nil {
                cancelled = true; tf.abortEditing(); finishInline(tf, commit: false); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ n: Notification) {
            guard editingURL != nil, let tf = n.object as? NSTextField else { return }
            finishInline(tf, commit: !cancelled)
        }
        func finishInline(_ tf: NSTextField, commit: Bool) {
            guard let u = editingURL else { return }
            editingURL = nil
            let name = tf.stringValue
            tf.delegate = nil
            (tf.superview as? DrawCell)?.endEditing()
            app.inlineRename = nil
            if commit { app.rename(u, to: name) }
            sync()
            table?.window?.makeFirstResponder(table)
        }
        /// 只增删变化的行（和访达一样，批量移走/移入时不重建整个表格）；顺序有变化时返回 false 改用 reloadData
        func applyIncremental(_ tv: NSTableView, old: [Row]) -> Bool {
            func key(_ r: Row) -> String { switch r { case .header(let t, _): return "\u{1}" + t; case .item(let it): return it.url.path } }
            guard !old.isEmpty, !rows.isEmpty, tv.numberOfRows == old.count else { return false }
            let ok = old.map(key), nk = rows.map(key)
            if ok == nk {
                // 行没变：只刷新内容变了的可见行
                let vis = tv.rows(in: tv.visibleRect)
                var idx = IndexSet()
                for i in vis.location..<min(vis.location + vis.length, rows.count) {
                    if case .item(let a) = old[i], case .item(let b) = rows[i], a == b { continue }
                    idx.insert(i)
                }
                if !idx.isEmpty { tv.reloadData(forRowIndexes: idx, columnIndexes: IndexSet(integersIn: 0..<tv.numberOfColumns)) }
                return true
            }
            let oset = Set(ok), nset = Set(nk)
            let kept0 = ok.filter { nset.contains($0) }, kept1 = nk.filter { oset.contains($0) }
            guard kept0 == kept1, !kept0.isEmpty else { return false }
            var removed = IndexSet(), inserted = IndexSet()
            for (i, k) in ok.enumerated() where !nset.contains(k) { removed.insert(i) }
            for (i, k) in nk.enumerated() where !oset.contains(k) { inserted.insert(i) }
            tv.beginUpdates()
            if !removed.isEmpty { tv.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { tv.insertRows(at: inserted, withAnimation: []) }
            tv.endUpdates()
            // 保留下来的行若属性变了（大小、日期、分组计数等），只刷新可见部分
            let vis = tv.rows(in: tv.visibleRect)
            var map: [String: Row] = [:]; map.reserveCapacity(old.count)
            for r in old { map[key(r)] = r }
            var idx = IndexSet()
            for i in vis.location..<min(vis.location + vis.length, rows.count) where !inserted.contains(i) {
                switch (map[nk[i]], rows[i]) {
                case (.item(let a)?, .item(let b)) where a == b: continue
                default: idx.insert(i)
                }
            }
            if !idx.isEmpty { tv.reloadData(forRowIndexes: idx, columnIndexes: IndexSet(integersIn: 0..<tv.numberOfColumns)) }
            return true
        }
        func applySelection() {
            guard let tv = table else { return }
            let sel = tab.selection
            var idx = IndexSet()
            for (i, r) in rows.enumerated() { if case .item(let it) = r, sel.contains(it.url) { idx.insert(i) } }
            suppress = true; tv.selectRowIndexes(idx, byExtendingSelection: false); suppress = false
            if let f = idx.first { tv.scrollRowToVisible(f) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tv: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
        func tableView(_ tv: NSTableView, shouldSelectRow row: Int) -> Bool { item(row) != nil }
        func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { item(row) == nil ? 26 : 22 }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            if case .header(let title, let n) = rows[row] {
                let tf = NSTextField(labelWithString: "\(title)（\(n)）"); tf.font = .boldSystemFont(ofSize: 12)
                let v = NSTableCellView(); v.addSubview(tf); tf.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8), tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
                return v
            }
            guard let it = item(row) else { return nil }
            let id = col?.identifier.rawValue ?? ""
            let cid = NSUserInterfaceItemIdentifier("c_" + id)
            var cell = tv.makeView(withIdentifier: cid, owner: nil) as? DrawCell
            if cell == nil {
                let c = DrawCell(); c.identifier = cid
                c.isName = id == "name"; c.middleTrunc = id == "name" || id == "path"
                c.secondary = id != "name"; c.mono = id != "name"; c.rightAlign = id == "size"
                c.setAccessibilityElement(true); c.setAccessibilityRole(.staticText)
                cell = c
            }
            guard let c = cell else { return nil }
            if c.editor != nil && !samePath(editingURL, it.url) { c.endEditing() }
            switch id {
            case "name":
                c.text = it.name
                c.icon = ThumbCache.listIcon(it)
                c.tags = it.tags.isEmpty ? NSAttributedString() : tagDots(it.tags)
            case "date": c.text = fmtDate(it.modified)
            case "size": c.text = it.isFolderLike ? "--" : fmtBytes(it.size)
            case "path": c.text = (it.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            default: c.text = it.kind
            }
            c.alphaValue = it.hidden ? 0.5 : 1
            return c
        }
        func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
            col?.identifier.rawValue == "name" ? item(row)?.name : nil
        }
        func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !suppress, let d = tv.sortDescriptors.first, let k = SortKey(rawValue: d.key ?? "") else { return }
            tab.setSort(k, asc: d.ascending)
        }
        func tableViewSelectionDidChange(_ n: Notification) {
            guard !suppress else { return }
            let s = Set(selectedURLs); pushedSelection = s
            tab.selection = s
            if let r = table?.selectedRow, let it = item(r) { tab.anchor = it.url }
        }

        @objc func doubleClick(_ s: Any?) {
            guard let tv = table, let it = item(tv.clickedRow) else { return }
            app.open(it, in: tab)
        }

        // Drag & drop
        func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { item(row).map { $0.url as NSURL } }
        func dropTarget(_ row: Int, _ op: NSTableView.DropOperation) -> URL {
            if op == .on, let it = item(row), it.isFolderLike { return it.url }
            return tab.path
        }
        func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            let urls = fileURLs(info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }
            var target = dropTarget(row, op)
            // 拖到自己身上（被拖的文件夹）= 放进当前文件夹
            if urls.contains(where: { samePath($0, target) }) { target = tab.path }
            if samePath(target, tab.path) { tv.setDropRow(-1, dropOperation: .on) }
            return dragOperation(planDrop(urls, to: target), info)
        }
        func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let urls = fileURLs(info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            var target = dropTarget(row, op)
            if urls.contains(where: { samePath($0, target) }) { target = tab.path }
            return app.performDrop(urls, to: target)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === headerMenu { menuForHeader(menu); return }
            guard let tv = table else { return }
            app.focusPane(pane)
            let r = tv.clickedRow
            if r >= 0 && item(r) != nil && !tv.selectedRowIndexes.contains(r) { tv.selectRowIndexes([r], byExtendingSelection: false) }
            let urls = r >= 0 && item(r) != nil ? selectedURLs : []
            ctrl.buildMenu(menu, urls: urls)
        }
    }
}

extension Notification.Name { static let fbColumnsChanged = Notification.Name("fbColumnsChanged") }
