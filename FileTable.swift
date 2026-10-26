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

final class FBTableView: NSTableView {
    weak var coord: FileTable.Coordinator?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let c = coord, c.app.active != c.pane { DispatchQueue.main.async { c.app.active = c.pane } }
        return ok
    }
    override func keyDown(with e: NSEvent) {
        guard let c = coord else { return super.keyDown(with: e) }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 49: c.quickLook(); return
        case 36, 76: if f.contains(.command) { c.openSelection() } else { c.renameSelection() }; return
        case 48: c.app.switchPane(); return
        case 51, 117: if f.contains(.command) { c.app.trash(c.selectedURLs); return }
        case 125: if f.contains(.command) { c.openSelection(); return }
        case 126: if f.contains(.command) { c.tab.goUp(); return }
        default: break
        }
        super.keyDown(with: e)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, let c = coord else { return super.performKeyEquivalent(with: e) }
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if f == .command {
            switch e.keyCode {
            case 51: c.app.trash(c.selectedURLs); return true
            case 125: c.openSelection(); return true
            default: break
            }
            switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "c": c.app.copyToClipboard(c.selectedURLs, cut: false); return true
            case "x": c.app.copyToClipboard(c.selectedURLs, cut: true); return true
            case "v": c.app.paste(into: c.tab.path); return true
            case "z": c.app.undo(); return true
            case "d": c.app.duplicate(c.selectedURLs); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: e)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = coord; panel.delegate = coord }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { }
}

struct FileTable: NSViewRepresentable {
    let tab: TabModel, app: AppState, paneIndex: Int, version: Int, selection: Set<URL>

    func makeCoordinator() -> Coordinator { Coordinator(app: app, tab: tab, pane: paneIndex) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = FBTableView(); tv.coord = c; c.table = tv
        tv.style = .fullWidth; tv.usesAlternatingRowBackgroundColors = true; tv.allowsMultipleSelection = true
        tv.rowHeight = 22; tv.intercellSpacing = NSSize(width: 6, height: 2); tv.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tv.allowsTypeSelect = true
        for (id, title, w) in [("name", "名称", 280.0), ("date", "修改日期", 135.0), ("size", "大小", 80.0), ("kind", "种类", 120.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = w; col.minWidth = id == "name" ? 120 : 50
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { col.headerCell.alignment = .right }
            tv.addTableColumn(col)
        }
        tv.autosaveName = "FBColumns\(paneIndex)"; tv.autosaveTableColumns = true
        tv.dataSource = c; tv.delegate = c
        tv.target = c; tv.doubleAction = #selector(Coordinator.doubleClick(_:))
        let menu = NSMenu(); menu.delegate = c; tv.menu = menu
        tv.registerForDraggedTypes([.fileURL])
        tv.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tv.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let sv = NSScrollView(); sv.documentView = tv; sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true; sv.autohidesScrollers = true
        sv.borderType = .noBorder
        app.tables[paneIndex].t = tv
        c.sync()
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.pane = paneIndex
        if c.tab !== tab { c.tab = tab; c.lastVersion = -1 }
        if let tv = c.table { app.tables[paneIndex].t = tv }
        c.sync()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        let app: AppState; var tab: TabModel; var pane: Int
        var items: [FileItem] = []; var lastVersion = -1; var suppress = false
        weak var table: FBTableView?
        var qlURLs: [URL] = []
        static let iconCache = NSCache<NSString, NSImage>()

        init(app: AppState, tab: TabModel, pane: Int) { self.app = app; self.tab = tab; self.pane = pane }

        var selectedURLs: [URL] { table?.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil } ?? [] }

        func sync() {
            guard let tv = table else { return }
            if lastVersion != tab.version {
                lastVersion = tab.version; items = tab.items
                suppress = true
                let d = NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.asc)
                if tv.sortDescriptors.first != d { tv.sortDescriptors = [d] }
                tv.reloadData(); suppress = false
                applySelection()
            } else {
                let cur = Set(selectedURLs.map { $0.standardizedFileURL })
                if cur != Set(tab.selection.map { $0.standardizedFileURL }) { applySelection() }
            }
        }
        func applySelection() {
            guard let tv = table else { return }
            let sel = Set(tab.selection.map { $0.standardizedFileURL })
            let idx = IndexSet(items.enumerated().filter { sel.contains($0.element.url.standardizedFileURL) }.map { $0.offset })
            suppress = true; tv.selectRowIndexes(idx, byExtendingSelection: false); suppress = false
            if let f = idx.first { tv.scrollRowToVisible(f) }
            refreshQL()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count else { return nil }
            let it = items[row], id = col?.identifier.rawValue ?? ""
            let cid = NSUserInterfaceItemIdentifier("c_" + id)
            var cell = tv.makeView(withIdentifier: cid, owner: nil) as? NSTableCellView
            if cell == nil {
                let c = NSTableCellView(); c.identifier = cid
                let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = id == "name" ? .byTruncatingMiddle : .byTruncatingTail
                c.addSubview(tf); c.textField = tf
                if id == "name" {
                    let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(iv); c.imageView = iv
                    NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                } else {
                    tf.textColor = .secondaryLabelColor
                    tf.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    if id == "size" { tf.alignment = .right }
                    NSLayoutConstraint.activate([tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                }
                cell = c
            }
            switch id {
            case "name":
                cell?.textField?.stringValue = it.name
                cell?.imageView?.image = icon(for: it.url)
            case "date": cell?.textField?.stringValue = fmtDate(it.modified)
            case "size": cell?.textField?.stringValue = it.isFolderLike ? "--" : fmtBytes(it.size)
            default: cell?.textField?.stringValue = it.kind
            }
            cell?.alphaValue = it.hidden ? 0.5 : 1
            return cell
        }
        func icon(for u: URL) -> NSImage {
            if let i = Coordinator.iconCache.object(forKey: u.path as NSString) { return i }
            let i = NSWorkspace.shared.icon(forFile: u.path); i.size = NSSize(width: 16, height: 16)
            Coordinator.iconCache.setObject(i, forKey: u.path as NSString); return i
        }
        func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
            col?.identifier.rawValue == "name" && row < items.count ? items[row].name : nil
        }
        func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !suppress, let d = tv.sortDescriptors.first, let k = SortKey(rawValue: d.key ?? "") else { return }
            tab.sortKey = k; tab.asc = d.ascending; tab.resort()
        }
        func tableViewSelectionDidChange(_ n: Notification) {
            guard !suppress else { return }
            tab.selection = Set(selectedURLs.map { $0.standardizedFileURL })
            refreshQL()
        }

        @objc func doubleClick(_ s: Any?) {
            guard let tv = table, tv.clickedRow >= 0, tv.clickedRow < items.count else { return }
            app.open(items[tv.clickedRow], in: tab)
        }
        func openSelection() {
            let sel = (table?.selectedRowIndexes ?? []).compactMap { $0 < items.count ? items[$0] : nil }
            guard !sel.isEmpty else { NSSound.beep(); return }
            if let folder = sel.first(where: { $0.isFolderLike }) { sel.filter { !$0.isFolderLike }.forEach { NSWorkspace.shared.open($0.url) }; tab.navigate(folder.url) }
            else { sel.forEach { NSWorkspace.shared.open($0.url) } }
        }
        func renameSelection() {
            let s = selectedURLs
            guard s.count == 1 else { NSSound.beep(); return }
            app.renameReq = RenameReq(url: s[0])
        }

        // Quick Look
        func quickLook() {
            guard let p = QLPreviewPanel.shared() else { return }
            if QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.orderOut(nil); return }
            qlURLs = selectedURLs
            guard !qlURLs.isEmpty else { NSSound.beep(); return }
            table?.window?.makeFirstResponder(table)
            p.makeKeyAndOrderFront(nil)
        }
        func refreshQL() {
            guard QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible, (p.dataSource as AnyObject?) === self else { return }
            qlURLs = selectedURLs; p.reloadData()
        }
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlURLs.count }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { qlURLs[index] as NSURL }
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            if event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 { table?.keyDown(with: event); return true }
            return false
        }

        // Drag & drop
        func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { row < items.count ? items[row].url as NSURL : nil }
        func dropTarget(_ row: Int, _ op: NSTableView.DropOperation) -> URL {
            (op == .on && row >= 0 && row < items.count && items[row].isFolderLike) ? items[row].url : tab.path
        }
        func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard let first = urls.first else { return [] }
            var target = dropTarget(row, op)
            if target == tab.path { tv.setDropRow(-1, dropOperation: .on); target = tab.path }
            if urls.contains(where: { $0.standardizedFileURL.path == target.standardizedFileURL.path }) { return [] }
            if NSEvent.modifierFlags.contains(.option) { return .copy }
            if sameVolume(first, target) {
                if first.deletingLastPathComponent().standardizedFileURL.path == target.standardizedFileURL.path { return [] }
                return .move
            }
            return .copy
        }
        func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            app.transfer(urls, to: dropTarget(row, op), mode: NSEvent.modifierFlags.contains(.option) ? .copy : .auto)
            return true
        }
        func tableView(_ tv: NSTableView, draggingSession session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
            if operation.contains(.move) || operation.contains(.delete) { tab.reload() }
        }

        // Context menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = table else { return }
            let r = tv.clickedRow
            if r >= 0 && !tv.selectedRowIndexes.contains(r) { tv.selectRowIndexes([r], byExtendingSelection: false) }
            let urls = r >= 0 ? selectedURLs : []
            let app = self.app, tab = self.tab, pane = self.pane
            func add(_ t: String, _ sym: String?, _ b: @escaping () -> Void) {
                let i = BlockMenuItem(t, b)
                if let s = sym { i.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
                menu.addItem(i)
            }
            if urls.isEmpty {
                add("新建文件夹", "folder.badge.plus") { app.active = pane; app.newFolder() }
                add("粘贴", "doc.on.clipboard") { app.paste(into: tab.path) }
                menu.addItem(.separator())
                add("在访达中显示", "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([tab.path]) }
                add("拷贝路径", "link") { copyPaths([tab.path]) }
                add("加入书签", "bookmark") { app.addBookmark(tab.path) }
                add("空间分析", "chart.pie") { app.sizeReq = SizeReq(url: tab.path) }
                return
            }
            add("打开", "arrow.up.forward.app") { self.openSelection() }
            let sub = NSMenu()
            for appURL in NSWorkspace.shared.urlsForApplications(toOpen: urls[0]).prefix(20) {
                let it = BlockMenuItem(FileManager.default.displayName(atPath: appURL.path)) {
                    NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, e in
                        if let e = e { DispatchQueue.main.async { app.showError("无法打开", e.localizedDescription) } }
                    }
                }
                let ic = NSWorkspace.shared.icon(forFile: appURL.path); ic.size = NSSize(width: 16, height: 16); it.image = ic
                sub.addItem(it)
            }
            let om = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: ""); om.submenu = sub
            om.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "没有可用的应用", action: nil, keyEquivalent: "")) }
            menu.addItem(om)
            add("快速查看", "eye") { self.quickLook() }
            add("在访达中显示", "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            add("拷贝路径", "link") { copyPaths(urls) }
            menu.addItem(.separator())
            if urls.count == 1 { add("重命名…", "pencil") { app.renameReq = RenameReq(url: urls[0]) } }
            add("拷贝", "doc.on.doc") { app.copyToClipboard(urls, cut: false) }
            add("剪切", "scissors") { app.copyToClipboard(urls, cut: true) }
            add("制作副本", "plus.square.on.square") { app.duplicate(urls) }
            if app.dual {
                add("拷贝到另一栏", "arrow.right.doc.on.clipboard") { app.transfer(urls, to: app.panes[1 - pane].tab.path, mode: .copy) }
                add("移动到另一栏", "arrow.right.square") { app.transfer(urls, to: app.panes[1 - pane].tab.path, mode: .move) }
            }
            menu.addItem(.separator())
            add("显示简介", "info.circle") { app.active = pane; app.showInfo = true }
            if urls.count == 1, items.first(where: { $0.url == urls[0] })?.isDir == true {
                add("加入书签", "bookmark") { app.addBookmark(urls[0]) }
                add("空间分析", "chart.pie") { app.sizeReq = SizeReq(url: urls[0]) }
            }
            menu.addItem(.separator())
            add("移到废纸篓", "trash") { app.trash(urls) }
        }
    }
}
