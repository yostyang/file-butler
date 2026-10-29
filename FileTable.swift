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
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = coord?.ctrl; panel.delegate = coord?.ctrl }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { }
}

final class NameCell: NSTableCellView {
    let tagField = NSTextField(labelWithString: "")
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

        func sync() { perfMark("sync \(Self.self) \(pane)") { sync0() } }
        func sync0() {
            guard let tv = table else { return }
            if lastVersion != tab.version {
                // 正在就地重命名时不要刷新表格（reloadData 会结束编辑），改完名再刷新
                if editingURL != nil { return }
                lastVersion = tab.version
                if tab.groupKey == .none || tab.isGlobalSearch { rows = tab.display.map { .item($0) } }
                else { rows = tab.groups.flatMap { g in [Row.header(g.0, g.1.count)] + g.1.map { Row.item($0) } } }
                layoutColumns()
                suppress = true
                let d = NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.asc)
                if tv.sortDescriptors.first != d { tv.sortDescriptors = [d] }
                tv.reloadData(); suppress = false
                applySelection()
            } else if Set(selectedURLs) != tab.selection { applySelection() }
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
            guard let cell = tv.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView, let tf = cell.textField, let it = item(row) else { if TestEnv.debug { print("DEBUG no cell row=\(row)") }; return }
            if TestEnv.debug { print("DEBUG editing row=\(row) win=\(tv.window != nil)") }
            editingURL = u; cancelled = false
            tf.isEditable = true; tf.isSelectable = true; tf.drawsBackground = true; tf.backgroundColor = .textBackgroundColor; tf.isBordered = true
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
            tf.isEditable = false; tf.drawsBackground = false; tf.isBordered = false; tf.delegate = nil
            app.inlineRename = nil
            if commit { app.rename(u, to: name) } else { tf.stringValue = u.lastPathComponent }
            sync()
            table?.window?.makeFirstResponder(table)
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
            var cell = tv.makeView(withIdentifier: cid, owner: nil) as? NSTableCellView
            if cell == nil {
                let c: NSTableCellView = id == "name" ? NameCell() : NSTableCellView(); c.identifier = cid
                let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = id == "name" || id == "path" ? .byTruncatingMiddle : .byTruncatingTail
                c.addSubview(tf); c.textField = tf
                if let nc = c as? NameCell {
                    let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false; nc.addSubview(iv); nc.imageView = iv
                    let tg = nc.tagField; tg.translatesAutoresizingMaskIntoConstraints = false; nc.addSubview(tg)
                    tg.setContentHuggingPriority(.required, for: .horizontal); tg.setContentCompressionResistancePriority(.required, for: .horizontal)
                    tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: nc.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: nc.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), tf.centerYAnchor.constraint(equalTo: nc.centerYAnchor),
                        tg.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 4), tg.trailingAnchor.constraint(lessThanOrEqualTo: nc.trailingAnchor, constant: -2),
                        tg.centerYAnchor.constraint(equalTo: nc.centerYAnchor)])
                } else {
                    tf.textColor = .secondaryLabelColor
                    tf.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    if id == "size" { tf.alignment = .right }
                    NSLayoutConstraint.activate([tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                }
                cell = c
            }
            if !samePath(editingURL, it.url), let tf = cell?.textField, tf.isEditable { tf.isEditable = false; tf.drawsBackground = false; tf.isBordered = false }
            switch id {
            case "name":
                cell?.textField?.stringValue = it.name
                cell?.imageView?.image = ThumbCache.listIcon(it)
                (cell as? NameCell)?.tagField.attributedStringValue = tagDots(it.tags)
            case "date": cell?.textField?.stringValue = fmtDate(it.modified)
            case "size": cell?.textField?.stringValue = it.isFolderLike ? "--" : fmtBytes(it.size)
            case "path": cell?.textField?.stringValue = (it.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            default: cell?.textField?.stringValue = it.kind
            }
            cell?.alphaValue = it.hidden ? 0.5 : 1
            return cell
        }
        func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
            col?.identifier.rawValue == "name" ? item(row)?.name : nil
        }
        func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !suppress, let d = tv.sortDescriptors.first, let k = SortKey(rawValue: d.key ?? "") else { return }
            tab.setSort(k, asc: d.ascending)
        }
        func tableViewSelectionDidChange(_ n: Notification) { perfMark("table selDidChange") { selDidChange() } }
        func selDidChange() {
            guard !suppress else { return }
            tab.selection = Set(selectedURLs)
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
