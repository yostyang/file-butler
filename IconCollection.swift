import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing

// MARK: - 图标视图（AppKit NSCollectionView）：原生框选、拖放、键盘导航，按需生成缩略图，右键菜单在弹出时才构建

final class FBCollectionView: NSCollectionView {
    weak var coord: IconCollection.Coordinator?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let c = coord, c.app.active != c.pane { let a = c.app, p = c.pane; DispatchQueue.main.async { a.active = p } }
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
    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        if e.clickCount == 2, let c = coord, let ip = indexPathForItem(at: convert(e.locationInWindow, from: nil)), let it = c.item(ip) {
            c.app.open(it, in: c.tab)
        }
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let c = coord else { return nil }
        c.app.focusPane(c.pane)
        var urls: [URL] = []
        if let ip = indexPathForItem(at: convert(e.locationInWindow, from: nil)), let it = c.item(ip) {
            if !c.tab.selection.contains(it.url) { c.tab.selection = [it.url]; c.tab.anchor = it.url; c.applySelection(scroll: false) }
            urls = c.tab.selectedURLs
        }
        let m = NSMenu(); c.ctrl.buildMenu(m, urls: urls); return m
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = coord?.ctrl; panel.delegate = coord?.ctrl }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { }
}

final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconItem")
    let bg = NSView(), iv = NSImageView(), label = NSTextField(wrappingLabelWithString: "")
    var url: URL?
    var thumbReq: QLThumbnailGenerator.Request?
    var dropTarget = false { didSet { updateLook() } }
    var iconSize: CGFloat = 80
    override func loadView() {
        let v = NSView(); v.wantsLayer = true
        bg.wantsLayer = true; bg.layer?.cornerRadius = 8
        iv.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 11); label.alignment = .center; label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle; label.cell?.truncatesLastVisibleLine = true
        label.wantsLayer = true; label.layer?.cornerRadius = 4
        [bg, iv, label].forEach { v.addSubview($0) }
        view = v
    }
    override var isSelected: Bool { didSet { updateLook() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateLook() } }
    func updateLook() {
        let sel = isSelected || highlightState == .forSelection
        bg.layer?.backgroundColor = sel ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : .clear
        bg.layer?.borderWidth = dropTarget ? 2 : 0
        bg.layer?.borderColor = NSColor(accentA).cgColor
        let editing = label.isEditable
        label.layer?.backgroundColor = sel && !editing ? NSColor(accentA).cgColor : .clear
        label.textColor = sel && !editing ? .white : .labelColor
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, s = iconSize
        bg.frame = NSRect(x: (w - s - 8) / 2, y: h - s - 8, width: s + 8, height: s + 8)
        iv.frame = bg.frame.insetBy(dx: 4, dy: 4)
        if label.isEditable { label.frame = NSRect(x: 0, y: h - s - 8 - 22, width: w, height: 20); return }
        let fit = label.sizeThatFits(NSSize(width: w - 6, height: 40))
        let lw = min(w - 2, fit.width + 8), lh = min(32, fit.height + 2)
        label.frame = NSRect(x: (w - lw) / 2, y: h - s - 10 - lh, width: lw, height: lh)
    }
    func configure(_ it: FileItem, size: CGFloat) {
        if let r = thumbReq { QLThumbnailGenerator.shared.cancel(r); thumbReq = nil }
        url = it.url; iconSize = size
        label.stringValue = it.name; label.toolTip = it.name
        view.alphaValue = it.hidden ? 0.5 : 1
        iv.image = ThumbCache.listIcon(it)
        let bucket = size <= 64 ? 64 : size <= 128 ? 128 : 256
        if !it.isFolderLike {
            let u = it.url
            thumbReq = ThumbCache.requestThumb(u, bucket: bucket) { [weak self] img in
                guard let img = img else { return }
                let apply = { if self?.url == u { self?.iv.image = img; self?.thumbReq = nil } }
                if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
            }
        }
        dropTarget = false
        updateLook(); view.needsLayout = true
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        if let r = thumbReq { QLThumbnailGenerator.shared.cancel(r); thumbReq = nil }
        url = nil
    }
}

final class IconHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("IconHeader")
    let tf = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        tf.font = .systemFont(ofSize: 12, weight: .semibold); addSubview(tf)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); tf.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: bounds.width - 12, height: 16) }
}

struct IconCollection: NSViewRepresentable {
    let tab: TabModel, app: AppState, paneIndex: Int, version: Int, selection: Set<URL>, iconSize: Double, renaming: URL?

    func makeCoordinator() -> Coordinator { Coordinator(app: app, tab: tab, pane: paneIndex) }
    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let cv = FBCollectionView(); cv.coord = c; c.cv = cv
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        cv.collectionViewLayout = layout
        cv.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        cv.register(IconHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: IconHeader.id)
        cv.isSelectable = true; cv.allowsMultipleSelection = true; cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.dataSource = c; cv.delegate = c
        cv.registerForDraggedTypes([.fileURL])
        cv.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        cv.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        let sv = NSScrollView(); sv.documentView = cv; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.drawsBackground = false; sv.borderType = .noBorder
        app.responders[paneIndex].v = cv
        c.sync()
        DispatchQueue.main.async { if app.active == paneIndex { cv.window?.makeFirstResponder(cv) } }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.pane = paneIndex
        if c.tab !== tab { c.tab = tab; c.lastVersion = -1 }
        if let cv = c.cv { app.responders[paneIndex].v = cv }
        c.sync()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
        let app: AppState; var tab: TabModel; var pane: Int
        weak var cv: FBCollectionView?
        var sections: [(String, [FileItem])] = []
        var index: [URL: IndexPath] = [:]
        var lastVersion = -1, lastSize: Double = -1, suppress = false
        var ctrl: PaneController { app.controllers[pane] }
        init(app: AppState, tab: TabModel, pane: Int) { self.app = app; self.tab = tab; self.pane = pane }

        func item(_ ip: IndexPath) -> FileItem? {
            guard ip.section < sections.count, ip.item < sections[ip.section].1.count else { return nil }
            return sections[ip.section].1[ip.item]
        }
        var size: CGFloat { CGFloat(app.iconSize) }
        func sync() {
            guard let cv = cv else { return }
            if lastVersion != tab.version || lastSize != app.iconSize {
                if editingURL != nil { return }
                lastVersion = tab.version
                if lastSize != app.iconSize { lastSize = app.iconSize; cv.collectionViewLayout?.invalidateLayout() }
                sections = (tab.groupKey == .none || tab.isGlobalSearch) ? [("", tab.display)] : tab.groups
                index = [:]
                for (s, g) in sections.enumerated() { for (i, it) in g.1.enumerated() { index[it.url] = IndexPath(item: i, section: s) } }
                suppress = true; cv.reloadData(); suppress = false
                applySelection(scroll: true)
            } else if Set(cv.selectionIndexPaths.compactMap { item($0)?.url }) != tab.selection { applySelection(scroll: true) }
            if app.inlineRename != nil && editingURL == nil { DispatchQueue.main.async { self.startInlineRename() } }
        }
        func applySelection(scroll: Bool) {
            guard let cv = cv else { return }
            let want = Set(tab.selection.compactMap { index[$0] })
            if want != cv.selectionIndexPaths { suppress = true; cv.selectionIndexPaths = want; suppress = false }
            if scroll, let a = tab.anchor.flatMap({ index[$0] }) ?? want.min(), cv.numberOfSections > a.section {
                let vis = cv.visibleRect
                if let f = cv.layoutAttributesForItem(at: a)?.frame, !vis.contains(f) { cv.scrollToItems(at: [a], scrollPosition: .nearestHorizontalEdge) }
            }
        }
        func selectionChanged(_ ips: Set<IndexPath>) {
            guard !suppress, let cv = cv else { return }
            tab.selection = Set(cv.selectionIndexPaths.compactMap { item($0)?.url })
            if let ip = ips.max(), let it = item(ip) { tab.anchor = it.url }
        }

        // data source
        func numberOfSections(in cv: NSCollectionView) -> Int { sections.count }
        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection s: Int) -> Int { sections[s].1.count }
        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let v = cv.makeItem(withIdentifier: IconItem.id, for: ip) as! IconItem
            if let it = item(ip) { v.configure(it, size: size); v.dropTarget = samePath(dropURL, it.url) }
            return v
        }
        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
            let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: IconHeader.id, for: ip) as! IconHeader
            let g = sections[ip.section]; h.tf.stringValue = "\(g.0)（\(g.1.count)）"
            return h
        }
        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt ip: IndexPath) -> NSSize { NSSize(width: size + 36, height: size + 8 + 40) }
        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection s: Int) -> NSSize {
            sections[s].0.isEmpty ? .zero : NSSize(width: cv.bounds.width, height: 26)
        }
        func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { selectionChanged(ips) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { selectionChanged([]) }

        // drag source
        func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with e: NSEvent) -> Bool { editingURL == nil }
        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? { item(ip).map { $0.url as NSURL } }

        // drop target：拖到文件夹图标上 = 放进该文件夹（高亮），拖到空白处 = 放进当前文件夹
        var pendingTarget: URL?
        var dropURL: URL? { didSet { if dropURL != oldValue { refreshDropHighlight(old: oldValue) } } }
        func refreshDropHighlight(old: URL?) {
            guard let cv = cv else { return }
            for u in [old, dropURL].compactMap({ $0 }) { if let ip = index[u], let v = cv.item(at: ip) as? IconItem { v.dropTarget = samePath(dropURL, u) } }
        }
        func target(for ip: IndexPath?, op: NSCollectionView.DropOperation, urls: [URL]) -> URL {
            if op == .on, let ip = ip, let it = item(ip), it.isFolderLike, !urls.contains(where: { samePath($0, it.url) }) { return it.url }
            return tab.path
        }
        func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath p: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let urls = fileURLs(info.draggingPasteboard)
            guard !urls.isEmpty else { dropURL = nil; return [] }
            let t = target(for: p.pointee as IndexPath, op: op.pointee, urls: urls)
            let k = planDrop(urls, to: t)
            pendingTarget = t
            dropURL = samePath(t, tab.path) || k == .none ? nil : t
            op.pointee = .on   // 不显示插入空隙；文件夹高亮由 dropURL 自己画
            return dragOperation(k, info)
        }
        func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath, dropOperation op: NSCollectionView.DropOperation) -> Bool {
            let urls = fileURLs(info.draggingPasteboard)
            dropURL = nil
            guard !urls.isEmpty else { return false }
            let t = pendingTarget ?? target(for: ip, op: op, urls: urls); pendingTarget = nil
            return app.performDrop(urls, to: t)
        }
        func collectionView(_ cv: NSCollectionView, draggingSession s: NSDraggingSession, endedAt p: NSPoint, dragOperation op: NSDragOperation) { dropURL = nil }

        // 就地重命名（回车 / 新建文件夹后）
        var editingURL: URL?
        var cancelled = false
        func startInlineRename() {
            guard let u = app.inlineRename, editingURL == nil, let cv = cv, let ip = index.first(where: { samePath($0.key, u) })?.value, let it = item(ip) else { return }
            cv.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
            guard let v = cv.item(at: ip) as? IconItem ?? { cv.layoutSubtreeIfNeeded(); return cv.item(at: ip) as? IconItem }() else { return }
            editingURL = u; cancelled = false
            let tf = v.label
            tf.isEditable = true; tf.isSelectable = true; tf.isBordered = true; tf.drawsBackground = true; tf.backgroundColor = .textBackgroundColor
            tf.maximumNumberOfLines = 1; tf.cell?.isScrollable = true; tf.cell?.wraps = false
            tf.delegate = self; v.updateLook(); v.view.needsLayout = true; v.view.layoutSubtreeIfNeeded()
            cv.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectedRange = baseNameRange(it.name, isDir: it.isDir)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)), let tf = control as? NSTextField, editingURL != nil {
                cancelled = true; tf.abortEditing(); finish(tf, commit: false); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ n: Notification) {
            guard editingURL != nil, let tf = n.object as? NSTextField else { return }
            finish(tf, commit: !cancelled)
        }
        func finish(_ tf: NSTextField, commit: Bool) {
            guard let u = editingURL else { return }
            editingURL = nil
            let name = tf.stringValue
            tf.isEditable = false; tf.isBordered = false; tf.drawsBackground = false; tf.delegate = nil
            tf.maximumNumberOfLines = 2; tf.cell?.wraps = true; tf.cell?.isScrollable = false
            app.inlineRename = nil
            if commit { app.rename(u, to: name) } else { tf.stringValue = u.lastPathComponent }
            lastVersion = -1; sync()
            cv?.window?.makeFirstResponder(cv)
        }
    }
}
