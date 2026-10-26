import SwiftUI
import AppKit
import QuickLookThumbnailing

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
                    if app.showInfo { InfoPanel().frame(minWidth: 220, idealWidth: 260, maxWidth: 360) }
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.newFolder() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }.help("新建文件夹 ⇧⌘N")
            Button { app.copyToOther(move: false) } label: { Label("拷贝到另一栏", systemImage: "doc.on.doc") }.help("拷贝到另一栏 F5").disabled(!app.dual)
            Button { app.copyToOther(move: true) } label: { Label("移动到另一栏", systemImage: "arrow.right.square") }.help("移动到另一栏 F6").disabled(!app.dual)
            Button { app.trash(app.activeTab.selectedURLs) } label: { Label("移到废纸篓", systemImage: "trash") }.help("移到废纸篓 ⌘⌫")
            Button { app.sizeReq = SizeReq(url: app.activeTab.path) } label: { Label("空间分析", systemImage: "chart.pie") }.help("分析当前文件夹占用空间 ⌥⌘S")
            Button { app.showHidden.toggle() } label: { Label("隐藏文件", systemImage: app.showHidden ? "eye" : "eye.slash") }.help("显示/隐藏隐藏文件 ⇧⌘.")
            Button { app.dual.toggle() } label: { Label("双栏", systemImage: app.dual ? "rectangle.split.2x1.fill" : "rectangle") }.help("单栏/双栏 ⌥⌘U")
            Button { app.showInfo.toggle() } label: { Label("信息面板", systemImage: "sidebar.right") }.help("信息与预览面板 ⌥⌘I")
        }
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
            Divider()
            ZStack {
                FileTable(tab: tab, app: app, paneIndex: index, version: tab.version, selection: tab.selection)
                if tab.permissionDenied { PermissionView() }
                else if let e = tab.error { VStack(spacing: 8) { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange); Text("无法读取这个文件夹"); Text(e).font(.caption).foregroundStyle(.secondary) }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor)) }
                else if tab.items.isEmpty && !tab.loading { Text("空文件夹").foregroundStyle(.secondary).allowsHitTesting(false) }
                if tab.loading && tab.items.isEmpty { ProgressView().controlSize(.small) }
            }
        }
    }
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
    @ObservedObject var tab: TabModel
    let busy: String?, dual: Bool, active: Int
    var body: some View {
        let sel = tab.selectedItems
        let selSize = sel.filter { !$0.isFolderLike }.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            if dual { Text(active == 0 ? "左栏" : "右栏").fontWeight(.semibold).foregroundStyle(accentA) }
            Text("\(tab.items.count) 个项目")
            if !sel.isEmpty { Text("已选 \(sel.count) 项，\(fmtBytes(selSize))" + (sel.contains { $0.isFolderLike } ? "（不含文件夹）" : "")) }
            if let b = busy { ProgressView().controlSize(.small); Text(b) }
            Spacer()
            if let f = freeSpace(tab.path) { Text("可用空间 \(fmtBytes(f))") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24)
    }
}

// MARK: Info panel
struct InfoPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View { InfoContent(tab: app.activeTab).id(app.activeTab.id) }
}
struct InfoContent: View {
    @ObservedObject var tab: TabModel
    @State var thumb: NSImage?
    var body: some View {
        let sel = tab.selectedItems
        let item = sel.first ?? makeItem(tab.path)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Spacer()
                    Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: item.url.path)).resizable().aspectRatio(contentMode: .fit).frame(width: 128, height: 128)
                    Spacer() }
                Text(item.name.isEmpty ? "/" : item.name).font(.headline).textSelection(.enabled)
                if sel.count > 1 { Text("已选 \(sel.count) 项（下方显示第一项）").font(.caption).foregroundStyle(.secondary) }
                if sel.isEmpty { Text("当前文件夹").font(.caption).foregroundStyle(.secondary) }
                Divider()
                info("种类", item.kind)
                info("大小", item.isFolderLike ? "--（用空间分析计算）" : "\(fmtBytes(item.size))（\(item.size) 字节）")
                info("创建时间", fmtDate(item.created))
                info("修改时间", fmtDate(item.modified))
                info("权限", perms(item.url))
                info("位置", item.url.path)
                HStack {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button("拷贝路径") { copyPaths([item.url]) }
                }.controlSize(.small)
            }.padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: item.url) { thumb = nil; loadThumb(item.url) }
    }
    func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v.isEmpty ? "--" : v).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    func perms(_ u: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path), let p = (a[.posixPermissions] as? NSNumber)?.intValue else { return "--" }
        let c = Array("rwxrwxrwx")
        let s = String((0..<9).map { p & (1 << (8 - $0)) != 0 ? c[$0] : "-" })
        return "\(s)（\(String(p, radix: 8))） 所有者：\(a[.ownerAccountName] as? String ?? "?")"
    }
    func loadThumb(_ u: URL) {
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 256, height: 256), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            if let img = rep?.nsImage { DispatchQueue.main.async { if tab.selectedItems.first?.url ?? tab.path == u { thumb = img } } }
        }
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
