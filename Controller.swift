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
        case 53: if tab.searchActive { tab.clearSearch(); return true }; return false
        case 51, 117: if f.contains(.command) { app.trash(tab.selectedURLs); return true }; return false
        case 125: if f.contains(.command) { openSelection(); return true }
        case 126: if f.contains(.command) { tab.goUp(); return true }
        default: break
        }
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
        guard f == .command else { return false }
        switch e.keyCode {
        case 51: app.trash(tab.selectedURLs); return true
        case 125: openSelection(); return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "c": app.copyToClipboard(tab.selectedURLs, cut: false); return true
        case "x": app.copyToClipboard(tab.selectedURLs, cut: true); return true
        case "v": app.paste(into: tab.path); return true
        case "z": app.undo(); return true
        case "d": app.duplicate(tab.selectedURLs); return true
        case "a": tab.selection = Set(tab.display.map { $0.url }); return true
        default: return false
        }
    }

    // MARK: Quick Look
    func quickLook(_ urls: [URL]? = nil) {
        guard let p = QLPreviewPanel.shared() else { return }
        if urls == nil && QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.orderOut(nil); return }
        qlURLs = urls ?? tab.selectedURLs
        guard !qlURLs.isEmpty else { NSSound.beep(); return }
        if let v = app.responders[pane].v { v.window?.makeFirstResponder(v) }
        p.dataSource = self; p.delegate = self
        p.makeKeyAndOrderFront(nil); p.reloadData()
    }
    func refreshQL() {
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
