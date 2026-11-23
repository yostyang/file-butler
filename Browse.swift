import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers
import CoreServices
import AVFoundation
import ImageIO

// MARK: thumbnails
/// 有上限的图标 / 缩略图缓存，内存吃紧时自动清空。
final class ThumbCache {
    static let images: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 48 << 20; c.countLimit = 800; return c }()
    static let icons: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 1500; return c }()
    static let typeIcons: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 400; return c }()
    static let pressure: DispatchSourceMemoryPressure = {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { ThumbCache.purge() }
        s.resume(); return s
    }()
    static func start() { _ = pressure }
    /// 每个文件单独的图标（文件夹、App 可能有自定义图标）
    static func icon(_ u: URL) -> NSImage {
        if let i = icons.object(forKey: u.path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: u.path); icons.setObject(i, forKey: u.path as NSString); return i
    }
    /// 普通文件按扩展名共用一个图标，不再为每个文件单独取图标
    static func listIcon(_ it: FileItem) -> NSImage {
        if it.isDir { return icon(it.url) }
        let ext = it.url.pathExtension.lowercased() as NSString
        if let i = typeIcons.object(forKey: ext) { return i }
        let t = UTType(filenameExtension: ext as String) ?? .data
        let i = NSWorkspace.shared.icon(for: t); typeIcons.setObject(i, forKey: ext); return i
    }
    @discardableResult
    static func requestThumb(_ u: URL, bucket: Int, done: @escaping (NSImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let key = "\(u.path)|\(bucket)" as NSString
        if let c = images.object(forKey: key) { done(c); return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: bucket, height: bucket), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let cg = rep?.cgImage else { done(nil); return }
            // 内容很少的文本文件，系统会生成一条细长的缩略图；这种情况保留文件图标（和访达一致）
            let ar = CGFloat(max(cg.width, cg.height)) / CGFloat(max(1, min(cg.width, cg.height)))
            if ar > 2.5 { done(nil); return }
            let i = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
            images.setObject(i, forKey: key, cost: cg.bytesPerRow * cg.height)
            done(i)
        }
        return req
    }
    static func purgeImages() { images.removeAllObjects() }
    static func purge() { images.removeAllObjects(); icons.removeAllObjects(); typeIcons.removeAllObjects() }
}
struct ThumbView: View {
    let item: FileItem; let size: CGFloat
    @State var img: NSImage?
    @State var req: QLThumbnailGenerator.Request?
    var bucket: Int { size <= 64 ? 64 : size <= 128 ? 128 : size <= 256 ? 256 : 512 }
    var body: some View {
        Image(nsImage: img ?? ThumbCache.listIcon(item)).resizable().aspectRatio(contentMode: .fit)
            // 文档缩略图多是白底，加一圈细阴影，像访达一样能看出纸张的边界
            .shadow(color: .black.opacity(img != nil ? 0.3 : 0), radius: 1.2, x: 0, y: 0.5)
            .task(id: "\(item.url.path)|\(bucket)|\(item.modified?.timeIntervalSince1970 ?? 0)") { load() }
            .onDisappear { if let r = req { QLThumbnailGenerator.shared.cancel(r) }; req = nil }   // 滚出屏幕就取消生成
    }
    func load() {
        if let r = req { QLThumbnailGenerator.shared.cancel(r); req = nil }
        img = nil
        guard !item.isFolderLike else { return }   // 文件夹直接用图标，不生成缩略图
        let u = item.url
        req = ThumbCache.requestThumb(u, bucket: bucket) { i in
            guard let i = i else { return }
            if Thread.isMainThread { if u == item.url { img = i } }
            else { DispatchQueue.main.async { if u == item.url { img = i; req = nil } } }
        }
    }
}

struct QLView: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true; v.shouldCloseWithWindow = false
        v.previewItem = url as NSURL?
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        let cur = (v.previewItem as? NSURL).map { $0 as URL }
        if cur != url { v.previewItem = url as NSURL? }
    }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

struct TagDotsView: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: -3) {
            ForEach(Array(tags.prefix(4).enumerated()), id: \.offset) { _, t in
                if let c = tagColor(t) { Circle().fill(Color(nsColor: c)).frame(width: 9, height: 9).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)) }
                else { Circle().stroke(Color.secondary, lineWidth: 1.2).frame(width: 8, height: 8) }
            }
        }
    }
}

func contextURLs(_ tab: TabModel, _ it: FileItem) -> [URL] { tab.selection.contains(it.url) ? tab.selectedURLs : [it.url] }

// MARK: icon view
struct IconGrid: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    var body: some View {
        let size = CGFloat(app.iconSize)
        let groups = tab.groups
        let order = tab.groupedOrder
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 36, maximum: size + 36), spacing: 6)], alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { g in
                            Section {
                                ForEach(g.1, id: \.url) { it in cell(it, size: size, order: order).id(it.url) }
                            } header: {
                                if !g.0.isEmpty {
                                    HStack { Text("\(g.0)（\(g.1.count)）").font(.system(size: 12, weight: .semibold)); Spacer() }
                                        .padding(.vertical, 4).padding(.horizontal, 6).background(.bar)
                                }
                            }
                        }
                    }.padding(12)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { tab.selection = []; app.focusPane(index) }
                }
                .onChange(of: tab.anchor) { a in if let a = a { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(a) } } }
            }
            .onAppear { app.controllers[index].iconColumns = max(1, Int((geo.size.width - 24) / (size + 42))) }
            .onChange(of: geo.size.width) { w in app.controllers[index].iconColumns = max(1, Int((w - 24) / (size + 42))) }
            .onChange(of: app.iconSize) { s in app.controllers[index].iconColumns = max(1, Int((geo.size.width - 24) / (CGFloat(s) + 42))) }
        }
        .background(KeyCatcher(app: app, pane: index))
        .contentShape(Rectangle())
        .onTapGesture { tab.selection = []; app.focusPane(index) }
        .onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: tab.path))
    }
    func cell(_ it: FileItem, size: CGFloat, order: [URL]) -> some View {
        let sel = tab.selection.contains(it.url)
        return VStack(spacing: 4) {
            ThumbView(item: it, size: size).frame(width: size, height: size).padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Color.primary.opacity(0.12) : .clear))
            HStack(spacing: 3) {
                if !it.tags.isEmpty { TagDotsView(tags: it.tags) }
                if samePath(app.inlineRename, it.url) { InlineNameField(url: it.url, isDir: it.isDir, app: app).frame(width: size + 30) }
                else { Text(it.name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle) }
            }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(sel ? accentA : .clear))
            .foregroundStyle(sel ? Color.white : Color.primary)
        }
        .frame(width: size + 36).opacity(it.hidden ? 0.5 : 1)
        .background(ItemMarkerView(url: it.url, tab: tab))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { app.open(it, in: tab) })
        .simultaneousGesture(TapGesture().onEnded { tab.click(it.url, order: order); app.focusPane(index) })
        .modifier(FolderDrop(app: app, item: it))
        .help(it.name)
    }
}
/// SwiftUI 视图（分栏、画廊、侧边栏、路径栏）的放下目标：光标显示的操作（移动 / 拷贝 +）与实际执行的一致，规则同访达
struct FinderDrop: DropDelegate {
    let app: AppState, dir: URL
    var targeted: Binding<Bool>? = nil
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { targeted?.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted?.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let urls = fileURLs(NSPasteboard(name: .drag))
        switch urls.isEmpty ? (DragMods.current.contains(.option) ? .copy : .move) : planDrop(urls, to: dir) {
        case .move: return DropProposal(operation: .move)
        case .copy: return DropProposal(operation: .copy)
        case .alias: return DropProposal(operation: .copy)   // SwiftUI 没有「替身」光标，用 + 号
        case .none: return DropProposal(operation: .forbidden)
        }
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted?.wrappedValue = false
        return FinderDrop.perform(app: app, dir: dir, pasteboard: NSPasteboard(name: .drag), providers: info.itemProviders(for: [.fileURL]))
    }
    /// 放下：先读拖动剪贴板里的全部文件。SwiftUI 的 DropInfo.itemProviders 在多选拖动（例如从列表视图拖 11 个文件）时
    /// 只给出第一个项目，以前因此只移动了一个文件。剪贴板里没有文件网址时才退回到 itemProviders。
    @discardableResult
    static func perform(app: AppState, dir: URL, pasteboard pb: NSPasteboard, providers: [NSItemProvider]) -> Bool {
        let urls = fileURLs(pb)
        if !urls.isEmpty { return app.performDrop(urls, to: dir) }
        return app.dropProviders(providers, to: dir)
    }
}
struct FolderDrop: ViewModifier {
    let app: AppState, item: FileItem
    @State var targeted = false
    func body(content: Content) -> some View {
        if item.isFolderLike {
            content.onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: item.url, targeted: $targeted))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentA, lineWidth: targeted ? 2 : 0))
        } else { content }
    }
}

// MARK: column view
final class ColumnLoader: ObservableObject {
    @Published var lists: [String: [FileItem]] = [:]
    private var waiters: [String: [([FileItem]) -> Void]] = [:]
    func load(_ u: URL, hidden: Bool, sortKey: SortKey, asc: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = sortItems(loadDirectory(u, hidden: hidden).items, key: sortKey, asc: asc)
            DispatchQueue.main.async {
                self.lists[u.path] = items
                if let w = self.waiters.removeValue(forKey: u.path) { w.forEach { $0(items) } }
            }
        }
    }
    /// 这一栏读完时回调一次（→ 键进入还没读完的文件夹时用）
    func whenLoaded(_ u: URL, _ f: @escaping ([FileItem]) -> Void) {
        if let l = lists[u.path] { f(l) } else { waiters[u.path, default: []].append(f) }
    }
}
struct ColumnBrowser: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    @StateObject var loader = ColumnLoader()
    var columns: [URL] { [tab.path] + tab.columnChain }
    var previewItem: FileItem? {
        guard tab.selection.count == 1, let u = tab.selection.first, u.deletingLastPathComponent().path == columns.last?.path else { return nil }
        let it = makeItem(u); return it.isFolderLike ? nil : it
    }
    var body: some View {
        GeometryReader { geo in
        let preview = previewItem
        let L = ColumnLayout(paneWidth: geo.size.width, columns: columns.count, preview: preview != nil)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { i, dir in
                        // 每栏固定 230 点宽，层级再深也不压缩（访达行为：横向滚动）
                        column(i, dir, height: geo.size.height).frame(width: ColumnLayout.columnWidth).fixedSize(horizontal: true, vertical: false).id("col\(i)")
                        Divider()
                    }
                    if let p = preview {
                        ColumnPreview(item: p).frame(width: L.previewWidth, height: geo.size.height).id("preview")
                    }
                    // 最后一栏右侧的空白：右键、放下都作用于最深的那个文件夹
                    Color.clear.frame(width: L.filler, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { app.focusPane(index); deselect(in: columns.count - 1) }
                        .background(ItemMarkerView(url: columns.last ?? tab.path, tab: tab, bg: true))
                        .onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: columns.last ?? tab.path))
                        .id("tail")
                }
                // 内容宽度明确给出：栏数 × 231 + 预览栏 + 右侧空白，任何情况下都不会被挤压
                .frame(width: L.total, height: geo.size.height, alignment: .leading)
            }
            // 底部横向滚动条（跟随系统设置：自动隐藏 / 始终显示）
            .scrollIndicators(.visible, axes: .horizontal)
            // 滚到最新一栏（连同右边的空白）；等这一轮排版完成后再滚，新加的栏才有位置
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("tail", anchor: .trailing) } }
            .onChange(of: tab.columnChain) { _ in DispatchQueue.main.async { withAnimation { proxy.scrollTo("tail", anchor: .trailing) } } }
            // 最新一栏的内容读完后再对齐一次（重绘可能打断上面的滚动动画）
            .onChange(of: loader.lists[tab.columnChain.last?.path ?? ""]?.count) { _ in if previewItem == nil { proxy.scrollTo("tail", anchor: .trailing) } }
            .onChange(of: tab.selection) { _ in if previewItem != nil { withAnimation { proxy.scrollTo("preview", anchor: .trailing) } } }
        }
        }
        .background(KeyCatcher(app: app, pane: index))
        .onAppear { tab.columnLoader = loader; for c in tab.columnChain { loader.load(c, hidden: app.showHidden, sortKey: tab.sortKey, asc: tab.asc) } }
        .onChange(of: tab.version) { _ in for c in tab.columnChain { loader.load(c, hidden: app.showHidden, sortKey: tab.sortKey, asc: tab.asc) } }
    }
    /// 点按某一栏的空白：取消选中这一栏里的项目（访达行为），保留左边栏的路径。
    func deselect(in i: Int) {
        tab.columnChain = Array(tab.columnChain.prefix(i))
        tab.selection = []
    }
    func column(_ i: Int, _ dir: URL, height: CGFloat) -> some View {
        let items = i == 0 ? tab.items : (loader.lists[dir.path] ?? [])
        let chosen: URL? = i < tab.columnChain.count ? tab.columnChain[i] : nil
        return ScrollViewReader { vp in ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.url) { it in
                    let sel = tab.selection.contains(it.url) || chosen == it.url
                    let strong = tab.selection.contains(it.url)
                    HStack(spacing: 6) {
                        Image(nsImage: ThumbCache.listIcon(it)).resizable().frame(width: 16, height: 16)
                        if samePath(app.inlineRename, it.url) { InlineNameField(url: it.url, isDir: it.isDir, app: app, fontSize: 12, center: false) }
                        else { Text(it.name).lineLimit(1).truncationMode(.middle).font(.system(size: 12)) }
                        Spacer(minLength: 2)
                        if !it.tags.isEmpty { TagDotsView(tags: it.tags) }
                        if it.isFolderLike { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(ItemMarkerView(url: it.url, tab: tab))
                    .background(RoundedRectangle(cornerRadius: 4).fill(sel ? (strong ? accentA : Color.primary.opacity(0.12)) : .clear))
                    .foregroundStyle(strong ? Color.white : Color.primary)
                    .opacity(it.hidden ? 0.5 : 1)
                    .contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).onEnded { app.open(it, in: tab) })
                    .simultaneousGesture(TapGesture().onEnded { select(it, at: i, items: items) })
                    .modifier(FolderDrop(app: app, item: it))
                }
            }.padding(4)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { app.focusPane(index); deselect(in: i) }
            .background(ItemMarkerView(url: dir, tab: tab, bg: true))
        }
        // 用键盘移动选择时，让选中的行保持可见
        .onChange(of: tab.anchor) { a in if let a = a, items.contains(where: { $0.url == a }) { vp.scrollTo(a) } }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: dir))
    }
    func select(_ it: FileItem, at i: Int, items: [FileItem]) {
        app.focusPane(index)
        let f = NSEvent.modifierFlags
        let dir = columns[i].standardizedFileURL.path
        let sameColumn = tab.selection.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == dir }
        if (f.contains(.command) || f.contains(.shift)) && sameColumn { tab.click(it.url, order: items.map { $0.url }); return }
        tab.columnChain = Array(tab.columnChain.prefix(i))
        if it.isFolderLike { tab.columnChain.append(it.url); loader.load(it.url, hidden: app.showHidden, sortKey: tab.sortKey, asc: tab.asc) }
        tab.selection = [it.url]; tab.anchor = it.url
    }
}

/// 分栏视图的宽度计算（纯函数，自检里验证）
struct ColumnLayout {
    static let columnWidth: CGFloat = 230
    let paneWidth: CGFloat, columns: Int, preview: Bool
    var columnsWidth: CGFloat { CGFloat(columns) * (ColumnLayout.columnWidth + 1) }
    /// 预览栏：占用剩下的宽度，最少 300、最多 600
    var previewWidth: CGFloat { preview ? max(300, min(600, paneWidth - columnsWidth - 40)) : 0 }
    var filler: CGFloat { max(40, paneWidth - columnsWidth - previewWidth) }
    var total: CGFloat { columnsWidth + previewWidth + filler }
}
/// 分栏视图最右边的预览栏（访达）：缩略图在可用空间里居中、按比例缩放，下面是名称、种类、大小、修改日期。
/// 影片 / 音频仍用不自动播放的媒体预览。
struct ColumnPreview: View {
    let item: FileItem
    static var lastLayout: (column: CGRect, image: CGRect)?   // 界面测试读取
    var body: some View {
        GeometryReader { g in
            let side = max(64, min(g.size.width - 32, g.size.height - 130))
            VStack(spacing: 6) {
                Spacer(minLength: 8)
                Group {
                    if isAVMedia(item.url) { PreviewSurface(url: item.url).frame(width: g.size.width - 32, height: side) }
                    else { ThumbView(item: item, size: side).frame(width: side, height: side) }
                }
                .background(GeometryReader { ig in Color.clear.onAppear { record(g, ig) }.onChange(of: ig.size) { _ in record(g, ig) } })
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center).padding(.top, 6)
                Text("\(item.kind) · \(fmtBytes(item.size))").font(.caption).foregroundStyle(.secondary)
                Text("修改于 \(fmtDate(item.modified))").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(width: g.size.width, height: g.size.height)
        }
    }
    func record(_ g: GeometryProxy, _ ig: GeometryProxy) {
        guard TestEnv.active else { return }
        ColumnPreview.lastLayout = (g.frame(in: .global), ig.frame(in: .global))
    }
}

// MARK: gallery view
struct GalleryView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    let index: Int
    var current: FileItem? { tab.selectedItems.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let it = current {
                    PreviewSurface(url: it.url).padding(12)
                    Divider()
                    MetaView(item: it).frame(width: 240)
                } else {
                    VStack { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.tertiary); Text("选择一个项目查看大图").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(tab.display, id: \.url) { it in
                            let sel = tab.selection.contains(it.url)
                            ThumbView(item: it, size: 64).frame(width: 64, height: 64).padding(5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(sel ? accentA.opacity(0.25) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? accentA : .clear, lineWidth: 2))
                                .overlay(alignment: .bottomTrailing) { if !it.tags.isEmpty { TagDotsView(tags: it.tags).padding(3) } }
                                .opacity(it.hidden ? 0.5 : 1)
                                .background(ItemMarkerView(url: it.url, tab: tab))
                                .contentShape(Rectangle())
                                .gesture(TapGesture(count: 2).onEnded { app.open(it, in: tab) })
                                .simultaneousGesture(TapGesture().onEnded { tab.click(it.url, order: tab.display.map { $0.url }); app.focusPane(index) })
                                .modifier(FolderDrop(app: app, item: it))
                                .help(it.name).id(it.url)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: tab.anchor) { a in if let a = a { withAnimation { proxy.scrollTo(a, anchor: .center) } } }
            }
            .frame(height: 96)
        }
        .background(KeyCatcher(app: app, pane: index))
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: FinderDrop(app: app, dir: tab.path))
        .onAppear { if tab.selection.isEmpty, let f = tab.display.first { tab.selection = [f.url]; tab.anchor = f.url } }
        .onChange(of: tab.version) { _ in if tab.selection.isEmpty, let f = tab.display.first { tab.selection = [f.url]; tab.anchor = f.url } }
    }
}

// MARK: metadata
struct MediaInfo { var dims: String?; var duration: String?; var seconds: Double? }
func mediaInfo(_ u: URL) -> MediaInfo {
    var r = spotlightMediaInfo(u)
    // Spotlight 没有索引到（新文件、/tmp 等）时直接读图片头
    if r.dims == nil, isImageFile(u), let s = CGImageSourceCreateWithURL(u as CFURL, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
       let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { r.dims = "\(w) × \(h)" }
    return r
}
/// 音视频未进 Spotlight 索引时，异步读取时长与尺寸（避免主线程同步阻塞与已弃用的 AVAsset 属性）
func loadAVMediaInfo(_ u: URL, base: MediaInfo) async -> MediaInfo {
    var r = base
    guard isAVMedia(u), r.seconds == nil || (isVideo(u) && r.dims == nil) else { return r }
    let a = AVURLAsset(url: u)
    if r.seconds == nil, let dur = try? await a.load(.duration) {
        let s = CMTimeGetSeconds(dur)
        if s.isFinite, s > 0 {
            r.seconds = s
            let sec = Int(s.rounded())
            r.duration = sec >= 3600 ? String(format: "%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60) : String(format: "%d:%02d", sec / 60, sec % 60)
        }
    }
    if isVideo(u), r.dims == nil, let t = (try? await a.loadTracks(withMediaType: .video))?.first,
       let (nat, tr) = try? await t.load(.naturalSize, .preferredTransform) {
        let sz = nat.applying(tr)
        r.dims = "\(Int(abs(sz.width))) × \(Int(abs(sz.height)))"
    }
    return r
}
func spotlightMediaInfo(_ u: URL) -> MediaInfo {
    guard let md = MDItemCreateWithURL(nil, u as CFURL) else { return MediaInfo() }
    var r = MediaInfo()
    if let w = MDItemCopyAttribute(md, kMDItemPixelWidth) as? NSNumber, let h = MDItemCopyAttribute(md, kMDItemPixelHeight) as? NSNumber { r.dims = "\(w.intValue) × \(h.intValue)" }
    defer {}
    if let d = MDItemCopyAttribute(md, kMDItemDurationSeconds) as? NSNumber {
        r.seconds = d.doubleValue
        let s = Int(d.doubleValue.rounded()); r.duration = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    return r
}
func permString(_ u: URL) -> String {
    guard let a = try? FileManager.default.attributesOfItem(atPath: u.path), let p = (a[.posixPermissions] as? NSNumber)?.intValue else { return "--" }
    let c = Array("rwxrwxrwx")
    return String((0..<9).map { p & (1 << (8 - $0)) != 0 ? c[$0] : "-" }) + "（\(String(p, radix: 8))） 所有者：\(a[.ownerAccountName] as? String ?? "?")"
}
struct MetaView: View {
    let item: FileItem
    var compactButtons = false
    @State private var avInfo: (URL, MediaInfo)?
    var body: some View {
        let m = avInfo?.0 == item.url ? avInfo!.1 : mediaInfo(item.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name.isEmpty ? "/" : item.name).font(.headline).textSelection(.enabled)
                if !item.tags.isEmpty { HStack(spacing: 6) { ForEach(item.tags, id: \.self) { t in HStack(spacing: 3) { TagDotsView(tags: [t]); Text(t).font(.caption) } } } }
                row("种类", item.kind)
                row("大小", item.isFolderLike ? "--（用空间分析计算）" : "\(fmtBytes(item.size))（\(item.size) 字节）")
                if let d = m.dims { row("尺寸", d) }
                if let d = m.duration { row("时长", d) }
                row("创建时间", fmtDate(item.created))
                row("修改时间", fmtDate(item.modified))
                row("权限", permString(item.url))
                row("位置", item.url.path)
                HStack(spacing: 6) {
                    Button("打开") { NSWorkspace.shared.open(item.url) }
                    ShareLink(items: [item.url]) { Label("共享", systemImage: "square.and.arrow.up") }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }.controlSize(.small)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.url) {
            let base = mediaInfo(item.url)
            let loaded = await loadAVMediaInfo(item.url, base: base)
            if !Task.isCancelled { avInfo = (item.url, loaded) }
        }
    }
    func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v.isEmpty ? "--" : v).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: preview panel (⇧⌘P)
struct PreviewPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View { PreviewContent(tab: app.activeTab).id(app.activeTab.id) }
}
struct PreviewContent: View {
    @ObservedObject var tab: TabModel
    var body: some View {
        let sel = tab.selectedItems
        VStack(spacing: 0) {
            if sel.count > 1 {
                let files = sel.filter { !$0.isFolderLike }
                VStack(spacing: 10) {
                    ZStack {
                        ForEach(Array(sel.prefix(3).enumerated()), id: \.offset) { i, it in
                            Image(nsImage: ThumbCache.icon(it.url)).resizable().frame(width: 96, height: 96).rotationEffect(.degrees(Double(i - 1) * 8)).offset(x: CGFloat(i - 1) * 14)
                        }
                    }.frame(height: 130)
                    Text("已选 \(sel.count) 项").font(.headline)
                    Text("\(files.count) 个文件，共 \(fmtBytes(files.reduce(0) { $0 + $1.size }))" + (sel.count > files.count ? "；\(sel.count - files.count) 个文件夹（大小未计算）" : ""))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ShareLink(items: sel.map { $0.url }) { Label("共享", systemImage: "square.and.arrow.up") }.controlSize(.small)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let item = sel.first ?? makeItem(tab.path)
                PreviewSurface(url: item.url).frame(minHeight: 220, maxHeight: 360).id(item.url)
                Divider()
                if sel.isEmpty { Text("当前文件夹").font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
                FinderInfoView(item: item, tab: tab).id(item.url)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: tags popover
struct TagPopover: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: TabModel
    @State var newTag = ""
    var body: some View {
        let urls = tab.selectedURLs
        VStack(alignment: .leading, spacing: 10) {
            Text(urls.isEmpty ? "先选中文件，再设置标签" : "为 \(urls.count) 个项目设置标签").font(.headline)
            HStack(spacing: 8) {
                ForEach(standardTags, id: \.0) { name, color in
                    let on = !urls.isEmpty && urls.allSatisfy { FileOps.readTags($0).contains(name) }
                    Button { app.toggleTag(name, urls) } label: {
                        ZStack {
                            Circle().fill(Color(nsColor: color)).frame(width: 22, height: 22)
                            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                        }
                    }.buttonStyle(.plain).help(name).disabled(urls.isEmpty)
                }
            }
            if !app.customTags.isEmpty {
                Divider()
                ForEach(app.customTags, id: \.self) { t in
                    let on = !urls.isEmpty && urls.allSatisfy { FileOps.readTags($0).contains(t) }
                    Button { app.toggleTag(t, urls) } label: {
                        HStack { Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? accentA : .secondary); Text(t); Spacer() }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(urls.isEmpty)
                }
            }
            Divider()
            HStack {
                TextField("新标签名称", text: $newTag).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty || urls.isEmpty)
            }
        }.padding(14).frame(width: 300)
    }
    func add() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !tab.selectedURLs.isEmpty else { return }
        app.toggleTag(t, tab.selectedURLs.filter { !FileOps.readTags($0).contains(t) }.isEmpty ? [] : tab.selectedURLs.filter { !FileOps.readTags($0).contains(t) })
        newTag = ""
    }
}
