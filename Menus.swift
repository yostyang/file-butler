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
    (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.count ?? 0
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
            .item("加入书签", nil, false, true) { app.addBookmark(dir) },
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
    m.append(.item("重新命名", nil, false, one) { app.active = pane; app.beginRename(urls[0]) })
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
    ]
    if urls.count >= 1 { extra.append(.item("用所选项目新建文件夹", sym("folder.badge.plus"), false, true) { app.active = pane; app.newFolderWithItems(urls) }) }
    if app.dual {
        extra.append(.item("拷贝到另一栏", sym("arrow.right.doc.on.clipboard"), false, true) { app.transfer(urls, to: other, mode: .copy) })
        extra.append(.item("移动到另一栏", sym("arrow.right.square"), false, true) { app.transfer(urls, to: other, mode: .move) })
    }
    if one, items[0].isDir {
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
struct InlineNameField: NSViewRepresentable {
    let url: URL, isDir: Bool, app: AppState
    var fontSize: CGFloat = 11, center = true
    func makeCoordinator() -> C { C(url: url, app: app) }
    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: url.lastPathComponent)
        tf.delegate = context.coordinator; tf.font = .systemFont(ofSize: fontSize); tf.alignment = center ? .center : .left
        tf.isBordered = true; tf.focusRingType = .exterior; tf.lineBreakMode = .byTruncatingMiddle; tf.cell?.isScrollable = true
        let r = baseNameRange(url.lastPathComponent, isDir: isDir)
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf); tf.currentEditor()?.selectedRange = r }
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

/// 右键时间戳：只有真正的右键（或 ⌃点按）才会让 SwiftUI 菜单先选中被点的项目，和访达一致。
enum RightClick {
    static var last: Date = .distantPast
    static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
            if e.type == .rightMouseDown || e.modifierFlags.contains(.control) { last = Date() }
            return e
        }
    }
    static var recent: Bool { Date().timeIntervalSince(last) < 0.6 }
}
/// 构建项目菜单时，如果被右键的项目没选中，先把它选中（异步，避免在视图更新中改状态）。
func itemMenuURLs(_ tab: TabModel, _ it: FileItem) -> [URL] {
    if tab.selection.contains(it.url) { return tab.selectedURLs }
    if RightClick.recent { DispatchQueue.main.async { if !tab.selection.contains(it.url) { tab.selection = [it.url]; tab.anchor = it.url } } }
    return [it.url]
}

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
