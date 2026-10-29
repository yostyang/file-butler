import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    PaneView(pane: app.panes[0], index: 0)
                    if app.dual { PaneView(pane: app.panes[1], index: 1) }
                    if app.showPreview { PreviewPanel().frame(minWidth: 240, idealWidth: 300, maxWidth: 480) }
                }
                Divider()
                StatusBar()
            }
            .toolbar { toolbar }
        }
        .navigationTitle(app.activeTab.title)
        .sheet(isPresented: $app.showFDA) { FDASheet() }
        .sheet(isPresented: $app.showViewOptions) { ViewOptionsSheet().environmentObject(app) }
        .onAppear { RightClick.install(app) }
        .sheet(item: $app.renameReq, onDismiss: { app.focusActiveTable() }) { r in RenameSheet(url: r.url).environmentObject(app) }
        .sheet(item: $app.sizeReq, onDismiss: { app.focusActiveTable() }) { r in SizeAnalysisView(rootURL: r.url).environmentObject(app) }
        .alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            if app.alert?.fda == true { Button("打开完全磁盘访问权限设置") { NSWorkspace.shared.open(fdaURL) } }
            Button("好", role: .cancel) {}
        } message: { Text(app.alert?.message ?? "") }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.focusActiveTable() }
            if TestEnv.active { UITestRunner.start(app: app); return }
            if !hasFullDiskAccess() && !UserDefaults.standard.bool(forKey: "fdaPromptDismissed") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.showFDA = true }
            }
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { app.activeTab.goBack() } label: { Label("后退", systemImage: "chevron.left") }.help("后退 ⌘[")
            Button { app.activeTab.goForward() } label: { Label("前进", systemImage: "chevron.right") }.help("前进 ⌘]")
            Button { app.activeTab.goUp() } label: { Label("上级", systemImage: "arrow.up") }.help("上级文件夹 ⌘↑")
        }
        ToolbarItem(placement: .primaryAction) { ViewModePicker(tab: app.activeTab, chrome: app.activeTab.chrome) }
        ToolbarItem(placement: .primaryAction) { GroupMenu(tab: app.activeTab, chrome: app.activeTab.chrome) }
        ToolbarItem(placement: .primaryAction) {
            Button { app.dual.toggle() } label: { Label("双栏", systemImage: app.dual ? "rectangle.split.2x1.fill" : "rectangle") }.help("单栏/双栏 ⌥⌘U")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.newFolder() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }.help("新建文件夹 ⇧⌘N")
            ShareButton(tab: app.activeTab, chrome: app.activeTab.chrome)
            TagButton(tab: app.activeTab)
            MoreMenu(tab: app.activeTab, pane: app.active)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.sizeReq = SizeReq(url: app.activeTab.path) } label: { Label("空间分析", systemImage: "chart.pie") }.help("分析当前文件夹占用空间 ⌥⌘S")
            Button { app.showPreview.toggle() } label: { Label("预览", systemImage: "sidebar.right") }.help("预览面板 ⇧⌘P")
        }
        ToolbarItem(placement: .primaryAction) { SearchBox(tab: app.activeTab, chrome: app.activeTab.chrome).id(app.activeTab.id) }
    }
}

struct ViewModePicker: View {
    @EnvironmentObject var app: AppState
    let tab: TabModel
    @ObservedObject var chrome: TabChrome
    var body: some View {
        Picker("显示方式", selection: Binding(get: { chrome.viewMode }, set: { app.setViewMode($0) })) {
            ForEach(ViewMode.allCases, id: \.self) { m in Label(m.title, systemImage: m.symbol).labelStyle(.iconOnly).tag(m) }
        }.pickerStyle(.segmented).help("图标 ⌘1 · 列表 ⌘2 · 分栏 ⌘3 · 画廊 ⌘4")
    }
}
struct GroupMenu: View {
    let tab: TabModel
    @ObservedObject var chrome: TabChrome
    var body: some View {
        Menu {
            Toggle("使用分组", isOn: Binding(get: { chrome.groupKey != .none }, set: { tab.groupKey = $0 ? .kind : .none }))
            Picker("分组方式", selection: Binding(get: { chrome.groupKey }, set: { tab.groupKey = $0 })) { ForEach(GroupKey.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            Divider()
            Picker("排序方式", selection: Binding(get: { chrome.sortKey }, set: { tab.setSort($0, asc: tab.asc) })) { ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            Picker("顺序", selection: Binding(get: { chrome.asc }, set: { tab.setSort(tab.sortKey, asc: $0) })) { Text("升序").tag(true); Text("降序").tag(false) }.pickerStyle(.inline)
        } label: { Label("分组", systemImage: "square.grid.3x1.below.line.grid.1x2") }
        .help("分组与排序方式")
    }
}
struct ShareButton: View {
    let tab: TabModel
    @ObservedObject var chrome: TabChrome
    // 共享面板在点按时才创建（选中几千个项目时不在每次刷新界面时构建 ShareLink）
    var body: some View {
        Button {
            let urls = tab.selectedURLs
            guard !urls.isEmpty, let w = NSApp.keyWindow, let v = w.contentView else { NSSound.beep(); return }
            let p = NSSharingServicePicker(items: urls)
            let loc = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
            p.show(relativeTo: NSRect(x: loc.x, y: loc.y, width: 1, height: 1), of: v, preferredEdge: .minY)
        } label: { Label("共享", systemImage: "square.and.arrow.up") }
        .disabled(!chrome.hasSelection).help("共享所选项目（隔空投送、邮件、信息等）")
    }
}
struct TagButton: View {
    @EnvironmentObject var app: AppState
    let tab: TabModel
    @State var show = false
    var body: some View {
        Button { show.toggle() } label: { Label("标签", systemImage: "tag") }.help("设置标签")
            .popover(isPresented: $show, arrowEdge: .bottom) { TagPopover(tab: tab) }
            .onChange(of: app.tagPopoverTick) { _ in show = true }
    }
}
struct MoreMenu: View {
    @EnvironmentObject var app: AppState
    let tab: TabModel
    let pane: Int
    // 菜单在点按时才构建（不在每次选中变化时查询「打开方式」等，避免卡顿）
    var body: some View {
        Button { popUp() } label: { Label("更多", systemImage: "ellipsis.circle") }.help("更多操作")
    }
    func popUp() {
        let t = tab, a = app, p = pane
        var e: [MEntry] = [.item("新建文件夹", nil, false, true) { a.active = p; a.newFolder() }]
        let sel = t.selectedURLs
        if !sel.isEmpty { e.append(.sep); e += contextSpec(app: a, tab: t, pane: p, urls: sel) }
        e += [.sep,
              .item(a.showPreview ? "隐藏预览" : "显示预览", nil, false, true) { a.showPreview.toggle() },
              .item(a.showHidden ? "不显示隐藏文件" : "显示隐藏文件", nil, false, true) { a.showHidden.toggle() },
              .item("空间分析", nil, false, true) { a.sizeReq = SizeReq(url: t.path) },
              .item("把当前文件夹加入书签", nil, false, true) { a.addBookmark(t.path) }]
        let m = NSMenu(); fillMenu(m, e, app: a)
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
struct SearchBox: View {
    @EnvironmentObject var app: AppState
    let tab: TabModel
    @ObservedObject var chrome: TabChrome
    @State var text = ""
    @FocusState var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索", text: $text).textFieldStyle(.plain).focused($focused)
                .onExitCommand { text = ""; tab.clearSearch(); app.focusActiveTable() }
            if !text.isEmpty || chrome.tagFilter != nil {
                Button { text = ""; tab.clearSearch(); app.focusActiveTable() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).frame(width: 190, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? accentA : Color.primary.opacity(0.15), lineWidth: focused ? 1.5 : 1))
        .onAppear { text = tab.searchText }
        .onChange(of: text) { tab.setSearch($0) }
        .onChange(of: chrome.searchText) { if $0 != text { text = $0 } }
        .onChange(of: app.searchFocus) { _ in
            focused = true
            // 工具栏里的 SwiftUI 焦点有时不生效：直接把搜索框设为第一响应者
            DispatchQueue.main.async {
                guard let w = app.responders[app.active].v?.window ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.toolbar != nil }) else { return }
                func find(_ v: NSView) -> NSTextField? {
                    if let t = v as? NSTextField, t.isEditable, t.window != nil, (t.placeholderString ?? t.placeholderAttributedString?.string) == "搜索" { return t }
                    for s in v.subviews { if let f = find(s) { return f } }
                    return nil
                }
                let roots = [w.contentView?.superview].compactMap { $0 } + (w.toolbar?.items.compactMap { $0.view } ?? [])
                if let tf = roots.lazy.compactMap(find).first, let w = tf.window, !(w.firstResponder is NSTextView && (w.firstResponder as? NSTextView)?.delegate === tf) { w.makeFirstResponder(tf) }
            }
        }
        .help("搜索 ⌘F")
    }
}

// MARK: Sidebar
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            Section("个人收藏") { ForEach(app.favorites, id: \.self) { row($0, name: $0.path.hasSuffix("CloudDocs") ? "iCloud 云盘" : nil) } }
            Section {
                if app.bookmarks.isEmpty { Text("点 + 收藏当前文件夹").font(.caption).foregroundStyle(.secondary) }
                ForEach(app.bookmarks, id: \.self) { u in
                    row(u).contextMenu { Button("移除书签") { app.removeBookmark(u) } }
                }
            } header: {
                HStack { Text("书签"); Spacer()
                    Button { app.addBookmark() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("把当前文件夹加入书签")
                }
            }
            Section("最近访问") { ForEach(Array(app.recents.prefix(15)), id: \.self) { row($0) } }
            Section("标签") {
                ForEach(app.allTags, id: \.self) { t in
                    Button { app.activeTab.showTag(t); app.objectWillChange.send() } label: {
                        HStack(spacing: 8) {
                            if let c = tagColor(t) { Circle().fill(Color(nsColor: c)).frame(width: 10, height: 10) } else { Circle().stroke(Color.secondary, lineWidth: 1.2).frame(width: 10, height: 10) }
                            Text(t).lineLimit(1)
                            Spacer(minLength: 0)
                        }.padding(.leading, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .fontWeight(app.activeTab.tagFilter == t ? .semibold : .regular)
                    .help("用 Spotlight 查找带「\(t)」标签的文件")
                }
            }
            Section("位置") {
                ForEach(app.volumes) { v in
                    Button { app.go(v.url) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: v.url.path)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).lineLimit(1)
                                Text("可用 \(fmtBytes(v.free))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(v.url.path)
                }
            }
        }.listStyle(.sidebar)
    }
    func row(_ u: URL, name: String? = nil) -> some View {
        let isCur = app.activeTab.path.path == u.standardizedFileURL.path
        return Button { app.go(u) } label: {
            HStack(spacing: 8) {
                Image(nsImage: safeFolderIcon(u)).resizable().frame(width: 16, height: 16)
                Text(name ?? cachedDisplayName(u.path)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).fontWeight(isCur ? .semibold : .regular)
        .foregroundStyle(isCur ? AnyShapeStyle(accentA) : AnyShapeStyle(.primary)).help(u.path)
        .onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: u))
    }
}

// MARK: Pane
struct PaneView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var pane: PaneModel
    let index: Int
    var body: some View {
        let isActive = app.active == index
        VStack(spacing: 0) {
            if app.dual || pane.tabs.count > 1 { TabBar(pane: pane, index: index, isActive: isActive) }
            TabContent(tab: pane.tab, index: index).id(pane.tab.id)
        }
        .overlay(alignment: .top) { if isActive && app.dual { Rectangle().fill(accentGrad).frame(height: 2) } }
        .frame(minWidth: 300)
    }
}

struct TabBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var pane: PaneModel
    let index: Int, isActive: Bool
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { i, t in
                        TabChip(tab: t, selected: i == pane.current, canClose: pane.tabs.count > 1,
                                select: { app.selectTab(pane: index, index: i) }, close: { app.closeTab(pane: index, index: i) })
                    }
                }.padding(.horizontal, 6)
            }
            Button { app.active = index; app.newTab() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("新建标签页 ⌘T").padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(isActive ? accentA.opacity(0.06) : Color(nsColor: .windowBackgroundColor))
    }
}

struct TabChip: View {
    @ObservedObject var tab: TabModel
    let selected: Bool, canClose: Bool, select: () -> Void, close: () -> Void
    @State var hover = false
    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: safeFolderIcon(tab.path)).resizable().frame(width: 14, height: 14)
            Text(tab.title).lineLimit(1).font(.system(size: 12, weight: selected ? .semibold : .regular))
            if canClose && (hover || selected) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.borderless).help("关闭标签页 ⌘W")
            }
        }
        .padding(.horizontal, 10).frame(height: 24).frame(maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: .controlBackgroundColor) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? accentA.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Rectangle()).onTapGesture(perform: select).onHover { hover = $0 }
        .help(tab.path.path)
    }
}

struct TabContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    var body: some View {
        VStack(spacing: 0) {
            if app.showPathBar || app.editingPane == index { PathBar(tab: tab, index: index) }
            if tab.searchActive { SearchScopeBar(tab: tab) }
            Divider()
            ZStack {
                switch effectiveMode {
                case .list: FileTable(tab: tab, app: app, paneIndex: index, version: tab.version, selection: tab.selection, renaming: app.inlineRename)
                case .icon: IconCollection(tab: tab, app: app, paneIndex: index, version: tab.version, selection: tab.selection, iconSize: app.iconSize, renaming: app.inlineRename)
                case .column: ColumnBrowser(tab: tab, index: index)
                case .gallery: GalleryView(tab: tab, index: index)
                }
                if tab.isGlobalSearch {
                    if tab.searching && tab.display.isEmpty { ProgressView("正在用 Spotlight 搜索…").controlSize(.small) }
                    else if tab.display.isEmpty { Text("没有找到结果").foregroundStyle(.secondary).allowsHitTesting(false) }
                }
                else if tab.permissionDenied { PermissionView() }
                else if let e = tab.error { VStack(spacing: 8) { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange); Text("无法读取这个文件夹"); Text(e).font(.caption).foregroundStyle(.secondary) }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor)) }
                else if tab.display.isEmpty && !tab.loading && effectiveMode != .column { Text(tab.searchActive ? "没有匹配的项目" : "空文件夹").foregroundStyle(.secondary).allowsHitTesting(false) }
                if tab.loading && tab.items.isEmpty { ProgressView().controlSize(.small) }
            }
        }
    }
}

extension TabContent {
    var effectiveMode: ViewMode { tab.isGlobalSearch || (tab.searchActive && tab.viewMode == .column) ? .list : tab.viewMode }
}
struct SearchScopeBar: View {
    @ObservedObject var tab: TabModel
    var body: some View {
        HStack(spacing: 8) {
            if let t = tagFilter {
                Image(systemName: "tag.fill").foregroundStyle(tagColor(t).map { Color(nsColor: $0) } ?? accentA)
                Text("标签「\(t)」（整台 Mac）").font(.system(size: 12, weight: .medium))
            } else {
                Text("搜索：").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $tab.searchScope) { ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            if tab.searching { ProgressView().controlSize(.small) }
            Text("\(tab.display.count) 个结果" + (tab.isGlobalSearch && tab.display.count >= 2000 ? "（只显示前 2000 个）" : "")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("清除") { tab.clearSearch() }.buttonStyle(.borderless).font(.caption)
        }.padding(.horizontal, 10).frame(height: 30).background(accentA.opacity(0.06))
    }
    var tagFilter: String? { tab.tagFilter }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(accentGrad)
            Text("没有权限访问这个文件夹").font(.headline)
            Text("macOS 保护了这个位置。打开「系统设置 › 隐私与安全性 › 完全磁盘访问权限」，打开「文件管家」的开关，然后重新打开本 App。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Button("打开完全磁盘访问权限设置") { NSWorkspace.shared.open(fdaURL) }.buttonStyle(.borderedProminent).tint(accentA)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: 路径栏（与访达一致：显示选中项的完整路径；太长时压缩中间段，首尾完整）
let rootVolumeName: String = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
let pbFont = NSFont.systemFont(ofSize: 12)
let pbPad: CGFloat = 26      // 图标 14 + 间距 4 + 左右内边距 8
let pbChevron: CGFloat = 14  // 分隔箭头 + 两侧间距
let pbMinText: CGFloat = 40
func pbTextWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: pbFont]).width) }
func pathURLs(_ target: URL) -> [URL] {
    var out = [URL(fileURLWithPath: "/")], cur = "/"
    for c in target.standardizedFileURL.pathComponents.dropFirst() where c != "/" && !c.isEmpty {
        cur = (cur as NSString).appendingPathComponent(c); out.append(URL(fileURLWithPath: cur))
    }
    return out
}
func pathLabel(_ u: URL) -> String { u.path == "/" ? rootVolumeName : cachedDisplayName(u.path) }
func truncMiddle(_ s: String, to w: CGFloat) -> String {
    if pbTextWidth(s) <= w { return s }
    let ch = Array(s)
    var k = ch.count - 1
    while k > 1 {
        let head = (k + 1) / 2, tail = k - head
        let c = String(ch.prefix(head)) + "…" + String(ch.suffix(tail))
        if pbTextWidth(c) <= w { return c }
        k -= 1
    }
    return String(ch.prefix(1)) + "…"
}
struct PBSeg: Hashable { var url: URL; var label: String; var hidden: [URL] = [] }
/// 纯函数布局：返回每段要显示的文字。先完整显示；放不下就把中间段压缩（每段至少 40pt）；还放不下就把中间段折叠成一个「…」菜单。
func pathBarLayout(_ urls: [URL], width: CGFloat) -> [PBSeg] {
    let labels = urls.map(pathLabel)
    let ws = labels.map(pbTextWidth)
    func overhead(_ n: Int) -> CGFloat { CGFloat(n) * pbPad + CGFloat(max(0, n - 1)) * pbChevron }
    if ws.reduce(0, +) + overhead(urls.count) <= width || urls.count <= 1 {
        return zip(urls, labels).map { PBSeg(url: $0, label: $1) }
    }
    if urls.count == 2 {
        let avail = max(pbMinText, width - overhead(2) - ws[1])
        return [PBSeg(url: urls[0], label: truncMiddle(labels[0], to: avail)), PBSeg(url: urls[1], label: truncMiddle(labels[1], to: max(pbMinText, width - overhead(2) - min(ws[0], avail))))]
    }
    let n = urls.count - 2
    let midAvail = width - ws[0] - ws[urls.count - 1] - overhead(urls.count)
    let mids = Array(ws[1..<(urls.count - 1)])
    if midAvail >= CGFloat(n) * pbMinText {
        // 水位法：找一个上限 c，使 sum(min(w, c)) <= midAvail
        var lo = pbMinText, hi = mids.max() ?? pbMinText
        for _ in 0..<30 { let c = (lo + hi) / 2; if mids.map({ min($0, c) }).reduce(0, +) <= midAvail { lo = c } else { hi = c } }
        var out = [PBSeg(url: urls[0], label: labels[0])]
        for i in 1..<(urls.count - 1) { out.append(PBSeg(url: urls[i], label: truncMiddle(labels[i], to: lo))) }
        out.append(PBSeg(url: urls[urls.count - 1], label: labels[urls.count - 1]))
        return out
    }
    // 折叠：首段 + 「…」 + 能放下的末尾若干段（最后一段始终显示）
    let ell = pbTextWidth("…") + 8
    var tailIdx = [urls.count - 1]
    var used = ws[0] + ws[urls.count - 1] + overhead(2) + ell + pbChevron
    var i = urls.count - 2
    while i >= 1, used + ws[i] + pbPad + pbChevron <= width { used += ws[i] + pbPad + pbChevron; tailIdx.insert(i, at: 0); i -= 1 }
    var out = [PBSeg(url: urls[0], label: labels[0])]
    let hiddenEnd = tailIdx.first!
    if hiddenEnd > 1 { out.append(PBSeg(url: urls[hiddenEnd - 1], label: "…", hidden: Array(urls[1..<hiddenEnd]))) }
    // 还是太长：先压缩第一段（磁盘名），最后一段尽量完整
    if used > width {
        let need = used - width
        let firstW = max(pbMinText, ws[0] - need)
        out[0].label = truncMiddle(labels[0], to: firstW)
        used -= ws[0] - pbTextWidth(out[0].label)
    }
    for j in tailIdx {
        let lastAvail = width - (used - ws[j])
        out.append(PBSeg(url: urls[j], label: j == urls.count - 1 ? truncMiddle(labels[j], to: max(pbMinText, lastAvail)) : labels[j]))
    }
    return out
}
func pathIcon(_ u: URL, isTarget: Bool, tab: TabModel) -> NSImage {
    if isTarget && u.standardizedFileURL.path != tab.path.standardizedFileURL.path {
        let it = makeItem(u); if !it.isFolderLike { return ThumbCache.listIcon(it) }
    }
    if u.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path { return homeFolderIcon }
    return safeFolderIcon(u)
}
let homeFolderIcon: NSImage = NSWorkspace.shared.icon(for: .folder)

struct PathBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    @State var text = ""
    @FocusState var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            if app.editingPane == index {
                Image(systemName: "arrow.right.circle").foregroundStyle(accentA)
                TextField(tab.path.path + "　（输入新路径，回车前往）", text: $text).textFieldStyle(.plain).focused($focused)
                    .onSubmit { guard !text.isEmpty else { app.editingPane = nil; return }; app.editingPane = nil; app.active = index; app.go(URL(fileURLWithPath: (text as NSString).expandingTildeInPath)) }
                    .onExitCommand { app.editingPane = nil; app.focusActiveTable() }
                    .onAppear { text = ""; DispatchQueue.main.async { focused = true } }
                Button("取消") { app.editingPane = nil; app.focusActiveTable() }.buttonStyle(.borderless).font(.caption)
            } else {
                GeometryReader { g in
                    PathSegmentsView(tab: tab, index: index, width: g.size.width)
                        .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                }
                Button { app.active = index; app.editingPane = index } label: { Image(systemName: "character.cursor.ibeam") }.buttonStyle(.borderless).help("输入路径 ⌘L / ⇧⌘G")
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
struct PathSegmentsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int, width: CGFloat
    var body: some View {
        let target = tab.pathTarget
        let segs = pathBarLayout(pathURLs(target), width: width)
        HStack(spacing: 0) {
            ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).frame(width: pbChevron) }
                if !s.hidden.isEmpty {
                    Menu {
                        ForEach(s.hidden, id: \.self) { u in Button(pathLabel(u)) { segmentClicked(u, isLast: false) } }
                    } label: { Text("…").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal, 4)
                    .help(s.hidden.map(pathLabel).joined(separator: " › "))
                } else {
                    Button { segmentClicked(s.url, isLast: i == segs.count - 1) } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: s.url.path == "/" ? ThumbCache.icon(s.url) : pathIcon(s.url, isTarget: i == segs.count - 1, tab: tab))
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14)
                            Text(s.label).font(.system(size: 12)).lineLimit(1).fixedSize()
                        }.padding(.horizontal, 4).padding(.vertical, 2).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(s.url.path).onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: s.url))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("pathbar-\(index)")
        .accessibilityValue(segs.map { $0.label }.joined(separator: " › "))
    }
    func segmentClicked(_ u: URL, isLast: Bool) {
        app.active = index
        let base = tab.path.standardizedFileURL.path, p = u.standardizedFileURL.path
        if tab.viewMode == .column && !tab.isGlobalSearch && p.hasPrefix(base + (base == "/" ? "" : "/")) && p != base {
            if isLast { return }
            if let k = tab.columnChain.firstIndex(where: { $0.standardizedFileURL.path == p }) { tab.columnChain = Array(tab.columnChain.prefix(k + 1)); tab.selection = []; return }
        }
        if isLast && !makeItem(u).isFolderLike { return }
        tab.navigate(u)
    }
}

// MARK: Status bar
struct StatusBar: View {
    @EnvironmentObject var app: AppState
    var body: some View { StatusContent(tab: app.activeTab, status: app.status, dual: app.dual, active: app.active) }
}
struct StatusContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    @ObservedObject var status: OpStatus
    let dual: Bool, active: Int
    var body: some View {
        let sum = tab.selectionSummary
        HStack(spacing: 10) {
            if dual { Text(active == 0 ? "左栏" : "右栏").fontWeight(.semibold).foregroundStyle(accentA) }
            Text("\(tab.display.count) 个项目")
            if sum.count > 0 { Text("已选 \(sum.count) 项，\(fmtBytes(sum.size))" + (sum.hasFolder ? "（不含文件夹）" : "")) }
            if let b = status.text {
                ProgressView().controlSize(.small); Text(b)
                Button { app.cancelOp() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("停止")
            }
            Spacer()
            if tab.viewMode == .icon && !tab.isGlobalSearch {
                Image(systemName: "photo").font(.system(size: 9))
                Slider(value: $app.iconSize, in: 32...256).frame(width: 110).controlSize(.mini)
                Image(systemName: "photo").font(.system(size: 13))
            }
            if let f = tab.freeBytes { Text("可用空间 \(fmtBytes(f))") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24)
    }
}

struct RenameSheet: View {
    let url: URL
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State var name: String
    init(url: URL) { self.url = url; _name = State(initialValue: url.lastPathComponent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32); Text("重命名").font(.headline) }
            TextField("名称", text: $name).frame(width: 360).onSubmit(commit)
            HStack { Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("重命名", action: commit).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20)
    }
    func commit() { let u = url, n = name; dismiss(); DispatchQueue.main.async { app.rename(u, to: n) } }
}

/// 侧边栏、标签页、路径栏用的图标：普通文件夹一律用通用文件夹图标，不去读取受保护文件夹里的内容
/// （读取自定义图标会触发「桌面 / 文稿 / 下载」等隐私授权弹窗）。
let genericFolderIcon = NSWorkspace.shared.icon(for: .folder)
let homeIcon: NSImage = NSImage(systemSymbolName: "house", accessibilityDescription: nil) ?? genericFolderIcon
func safeFolderIcon(_ u: URL) -> NSImage {
    let p = u.standardizedFileURL.path
    if p == "/" || p.hasPrefix("/Volumes/") && u.deletingLastPathComponent().path == "/Volumes" { return ThumbCache.icon(u) }
    if p == "/Applications" { return ThumbCache.icon(u) }
    return genericFolderIcon
}

/// 是否已授予「完全磁盘访问权限」：只读检查，不会触发任何弹窗。
func hasFullDiskAccess() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for p in [home + "/Library/Application Support/com.apple.TCC/TCC.db", home + "/Library/Safari/Bookmarks.plist", "/Library/Application Support/com.apple.TCC/TCC.db"] {
        let fd = open(p, O_RDONLY)
        if fd >= 0 { close(fd); return true }
    }
    return false
}

struct FDASheet: View {
    @Environment(\.dismiss) var dismiss
    @State var granted = hasFullDiskAccess()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield").font(.system(size: 34)).foregroundStyle(granted ? AnyShapeStyle(Color.green) : AnyShapeStyle(accentGrad))
                Text(granted ? "已获得完全磁盘访问权限" : "授予一次，以后不再弹窗").font(.title3.bold())
            }
            if granted {
                Text("文件管家现在可以直接访问桌面、文稿、下载、iCloud 云盘和外接磁盘，不会再逐个文件夹申请权限。").foregroundStyle(.secondary)
            } else {
                Text("macOS 会对「桌面」「文稿」「下载」、iCloud 云盘、外接磁盘等位置逐个弹窗申请权限。作为文件管理器，最省事的办法是一次性授予「完全磁盘访问权限」：").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 点下面的按钮，打开「隐私与安全性 › 完全磁盘访问权限」")
                    Text("2. 打开「文件管家」的开关（列表里没有就点 ＋ 添加 /Applications/文件管家.app）")
                    Text("3. 按提示退出并重新打开文件管家")
                }.font(.callout)
                Text("授权会一直有效，以后更新文件管家也不用重新授权。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !granted { Button("以后再说") { UserDefaults.standard.set(true, forKey: "fdaPromptDismissed"); dismiss() } }
                Spacer()
                if granted { Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
                else { Button("打开系统设置") { NSWorkspace.shared.open(fdaURL) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(accentA) }
            }
        }
        .padding(22).frame(width: 470)
        .onReceive(timer) { _ in if !granted { granted = hasFullDiskAccess() } }
    }
}
