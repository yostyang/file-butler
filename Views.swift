import SwiftUI
import AppKit

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
        .sheet(item: $app.renameReq, onDismiss: { app.focusActiveTable() }) { r in RenameSheet(url: r.url).environmentObject(app) }
        .sheet(item: $app.sizeReq, onDismiss: { app.focusActiveTable() }) { r in SizeAnalysisView(rootURL: r.url).environmentObject(app) }
        .alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            if app.alert?.fda == true { Button("打开完全磁盘访问权限设置") { NSWorkspace.shared.open(fdaURL) } }
            Button("好", role: .cancel) {}
        } message: { Text(app.alert?.message ?? "") }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.focusActiveTable() } }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { app.activeTab.goBack() } label: { Label("后退", systemImage: "chevron.left") }.help("后退 ⌘[")
            Button { app.activeTab.goForward() } label: { Label("前进", systemImage: "chevron.right") }.help("前进 ⌘]")
            Button { app.activeTab.goUp() } label: { Label("上级", systemImage: "arrow.up") }.help("上级文件夹 ⌘↑")
        }
        ToolbarItem(placement: .primaryAction) { ViewModePicker(tab: app.activeTab) }
        ToolbarItem(placement: .primaryAction) { GroupMenu(tab: app.activeTab) }
        ToolbarItem(placement: .primaryAction) {
            Button { app.dual.toggle() } label: { Label("双栏", systemImage: app.dual ? "rectangle.split.2x1.fill" : "rectangle") }.help("单栏/双栏 ⌥⌘U")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ShareButton(tab: app.activeTab)
            TagButton(tab: app.activeTab)
            MoreMenu(tab: app.activeTab, pane: app.active)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.sizeReq = SizeReq(url: app.activeTab.path) } label: { Label("空间分析", systemImage: "chart.pie") }.help("分析当前文件夹占用空间 ⌥⌘S")
            Button { app.showPreview.toggle() } label: { Label("预览", systemImage: "sidebar.right") }.help("预览面板 ⇧⌘P")
        }
        ToolbarItem(placement: .primaryAction) { SearchBox(tab: app.activeTab).id(app.activeTab.id) }
    }
}

struct ViewModePicker: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    var body: some View {
        Picker("显示方式", selection: Binding(get: { tab.viewMode }, set: { app.setViewMode($0) })) {
            ForEach(ViewMode.allCases, id: \.self) { m in Label(m.title, systemImage: m.symbol).labelStyle(.iconOnly).tag(m) }
        }.pickerStyle(.segmented).help("图标 ⌘1 · 列表 ⌘2 · 分栏 ⌘3 · 画廊 ⌘4")
    }
}
struct GroupMenu: View {
    @ObservedObject var tab: TabModel
    var body: some View {
        Menu {
            Toggle("使用分组", isOn: Binding(get: { tab.groupKey != .none }, set: { tab.groupKey = $0 ? .kind : .none }))
            Picker("分组方式", selection: $tab.groupKey) { ForEach(GroupKey.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            Divider()
            Picker("排序方式", selection: Binding(get: { tab.sortKey }, set: { tab.setSort($0, asc: tab.asc) })) { ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            Picker("顺序", selection: Binding(get: { tab.asc }, set: { tab.setSort(tab.sortKey, asc: $0) })) { Text("升序").tag(true); Text("降序").tag(false) }.pickerStyle(.inline)
        } label: { Label("分组", systemImage: "square.grid.3x1.below.line.grid.1x2") }
        .help("分组与排序方式")
    }
}
struct ShareButton: View {
    @ObservedObject var tab: TabModel
    var body: some View {
        let urls = tab.selectedURLs
        ShareLink(items: urls) { Label("共享", systemImage: "square.and.arrow.up") }.disabled(urls.isEmpty).help("共享所选项目（隔空投送、邮件、信息等）")
    }
}
struct TagButton: View {
    @ObservedObject var tab: TabModel
    @State var show = false
    var body: some View {
        Button { show.toggle() } label: { Label("标签", systemImage: "tag") }.help("设置标签")
            .popover(isPresented: $show, arrowEdge: .bottom) { TagPopover(tab: tab) }
    }
}
struct MoreMenu: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let pane: Int
    var body: some View {
        Menu {
            ItemActions(app: app, tab: tab, pane: pane, urls: tab.selectedURLs)
            Divider()
            Button(app.showPreview ? "隐藏预览" : "显示预览") { app.showPreview.toggle() }
            Button(app.showHidden ? "不显示隐藏文件" : "显示隐藏文件") { app.showHidden.toggle() }
            Button("空间分析") { app.sizeReq = SizeReq(url: tab.path) }
            Button("把当前文件夹加入书签") { app.addBookmark(tab.path) }
        } label: { Label("更多", systemImage: "ellipsis.circle") }.help("更多操作")
    }
}
struct SearchBox: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    @State var text = ""
    @FocusState var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索", text: $text).textFieldStyle(.plain).focused($focused)
                .onExitCommand { text = ""; tab.clearSearch(); app.focusActiveTable() }
            if !text.isEmpty || tab.tagFilter != nil {
                Button { text = ""; tab.clearSearch(); app.focusActiveTable() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).frame(width: 190, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? accentA : Color.primary.opacity(0.15), lineWidth: focused ? 1.5 : 1))
        .onAppear { text = tab.searchText }
        .onChange(of: text) { tab.setSearch($0) }
        .onChange(of: tab.searchText) { if $0 != text { text = $0 } }
        .onChange(of: app.searchFocus) { _ in focused = true }
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
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 16, height: 16)
                Text(name ?? FileManager.default.displayName(atPath: u.path)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).fontWeight(isCur ? .semibold : .regular)
        .foregroundStyle(isCur ? AnyShapeStyle(accentA) : AnyShapeStyle(.primary)).help(u.path)
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: tab.path.path)).resizable().frame(width: 14, height: 14)
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
            PathBar(tab: tab, index: index)
            if tab.searchActive { SearchScopeBar(tab: tab) }
            Divider()
            ZStack {
                switch effectiveMode {
                case .list: FileTable(tab: tab, app: app, paneIndex: index, version: tab.version, selection: tab.selection)
                case .icon: IconGrid(tab: tab, index: index)
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

struct PathBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    @State var text = ""
    @FocusState var focused: Bool
    var components: [URL] {
        var list: [URL] = []; var u = tab.path
        while true { list.insert(u, at: 0); let p = u.deletingLastPathComponent(); if p.path == u.path || list.count > 60 { break }; u = p }
        return list
    }
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
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(components.enumerated()), id: \.offset) { i, u in
                                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                                Button { app.active = index; tab.navigate(u) } label: {
                                    HStack(spacing: 4) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 14, height: 14)
                                        Text(u.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: u.path)).font(.system(size: 12)).lineLimit(1)
                                    }.padding(.horizontal, 4).padding(.vertical, 2).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(i)
                            }
                        }
                    }.onAppear { proxy.scrollTo(components.count - 1) }.onChange(of: tab.path) { _ in proxy.scrollTo(components.count - 1) }
                }
                Spacer(minLength: 0)
                Button { app.active = index; app.editingPane = index } label: { Image(systemName: "character.cursor.ibeam") }.buttonStyle(.borderless).help("输入路径 ⌘L / ⇧⌘G")
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: Status bar
struct StatusBar: View {
    @EnvironmentObject var app: AppState
    var body: some View { StatusContent(tab: app.activeTab, busy: app.busyText, dual: app.dual, active: app.active) }
}
struct StatusContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let busy: String?, dual: Bool, active: Int
    var body: some View {
        let sel = tab.selectedItems
        let selSize = sel.filter { !$0.isFolderLike }.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            if dual { Text(active == 0 ? "左栏" : "右栏").fontWeight(.semibold).foregroundStyle(accentA) }
            Text("\(tab.display.count) 个项目")
            if !sel.isEmpty { Text("已选 \(sel.count) 项，\(fmtBytes(selSize))" + (sel.contains { $0.isFolderLike } ? "（不含文件夹）" : "")) }
            if let b = busy { ProgressView().controlSize(.small); Text(b) }
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
