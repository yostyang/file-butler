import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - v0.6 文件架：从不同文件夹收集文件，再一起拷贝或移动。文件架只记住位置，移出 / 清空文件架绝不改动文件。

final class ShelfModel: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published var visible = false
    let storeKey: String
    init(storeKey: String = Settings.Key.shelfItems) {
        self.storeKey = storeKey
        items = Settings.stringList(forKey: storeKey).map { URL(fileURLWithPath: $0) }.filter { FileOps.lexists($0.path) }
    }
    private func save() { Settings.setStringList(items.map { $0.path }, forKey: storeKey) }
    /// 加入（按路径去重）。返回新加入的数量。
    @discardableResult func add(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls where u.isFileURL {
            let s = u.standardizedFileURL
            if !items.contains(where: { $0.path == s.path }) { items.append(s); n += 1 }
        }
        if n > 0 { save() }
        return n
    }
    /// 从文件架移出：只改文件架的列表，不碰磁盘上的文件
    func remove(_ urls: [URL]) {
        let gone = Set(urls.map { $0.standardizedFileURL.path })
        items.removeAll { gone.contains($0.path) }; save()
    }
    func clear() { items = []; save() }
    /// 移动之后，文件架跟着指向新位置
    func relocate(_ pairs: [(URL, URL)]) {
        // 文件架通常只有几项：先按名称筛，只对可能相关的项目做路径标准化（1000 项改名时原来要 32ms，文件架为空时也一样）
        guard !pairs.isEmpty, !items.isEmpty else { return }
        let names = Set(items.map { $0.lastPathComponent })
        var map: [String: URL] = [:]
        for (a, b) in pairs where names.contains(a.lastPathComponent) { map[a.standardizedFileURL.path] = b.standardizedFileURL }
        guard !map.isEmpty else { return }
        let new = items.map { map[$0.path] ?? $0 }
        if new != items { items = new; save() }
    }
    /// 去掉已经不存在的项目（例如在访达里删掉了）
    @discardableResult func prune() -> Int {
        let before = items.count
        items.removeAll { !FileOps.lexists($0.path) }
        if items.count != before { save() }
        return before - items.count
    }
}

extension AppState {
    func addToShelf(_ urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        shelf.add(urls); shelf.visible = true
    }
    /// 拖到文件架上：只记下位置
    func addProvidersToShelf(_ ps: [NSItemProvider]) {
        let group = DispatchGroup(), lock = NSLock(); var urls: [URL] = []
        for p in ps where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in if let u = u, u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }; group.leave() }
        }
        group.notify(queue: .main) { if !urls.isEmpty { self.shelf.add(urls); self.shelf.visible = true } }
    }
    /// 把文件架上的全部项目拷贝 / 移动到某个文件夹（默认是当前栏正在显示的文件夹）。
    /// 走和粘贴、拖放完全相同的入口：访达式进度窗口、同名冲突对话框（保留两者 / 停止 / 替换）、⌘Z 撤销。
    func shelfTransfer(move: Bool, to dir: URL? = nil) {
        shelf.prune()
        let urls = shelf.items
        guard !urls.isEmpty else { NSSound.beep(); return }
        let dest = dir ?? activeController.pasteDir
        if activeTab.isGlobalSearch && dir == nil { showError("无法放到这里", "请先结束搜索，再选择要放入的文件夹。"); return }
        transfer(urls, to: dest, mode: move ? .move : .copy) { [weak self] r in
            if move { self?.shelf.relocate(r.moved) }
        }
    }
}

/// 窗口底部的文件架（只有打开时才在界面里）
struct ShelfContainer: View {
    @ObservedObject var shelf: ShelfModel
    var body: some View {
        if shelf.visible { VStack(spacing: 0) { Divider(); ShelfBar(shelf: shelf) } }
    }
}

struct ShelfBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var shelf: ShelfModel
    @State var targeted = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full").foregroundStyle(accentA)
            Text("文件架").font(.system(size: 12, weight: .semibold))
            Text("\(shelf.items.count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
            if shelf.items.isEmpty {
                Text("把文件拖到这里，或在右键菜单里选「加入文件架」（只记住位置，不会移动文件）").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(shelf.items, id: \.self) { u in ShelfChip(url: u) { shelf.remove([u]) } } }
                }
                ShelfDragAll(urls: shelf.items).frame(width: 26, height: 22).help("把文件架上的全部项目拖到某个文件夹（同一磁盘默认移动，按住 ⌥ 拷贝，与访达一致）")
            }
            Button("拷贝到这里") { app.shelfTransfer(move: false) }.disabled(shelf.items.isEmpty).help("拷贝到当前栏的文件夹")
            Button("移动到这里") { app.shelfTransfer(move: true) }.disabled(shelf.items.isEmpty).help("移动到当前栏的文件夹（可用 ⌘Z 撤销）")
            Button("清空") { shelf.clear() }.disabled(shelf.items.isEmpty).help("只清空文件架，不会改动任何文件")
            Button { shelf.visible = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("隐藏文件架")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).frame(height: 40)
        .background(targeted ? accentA.opacity(0.14) : accentA.opacity(0.05))
        .onDrop(of: [.fileURL], delegate: ShelfDrop(app: app, targeted: $targeted))
        .accessibilityIdentifier("shelf-bar")
    }
}

/// 放到文件架上：光标显示「+」，只登记位置
struct ShelfDrop: DropDelegate {
    let app: AppState
    var targeted: Binding<Bool>
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { targeted.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        // 多选拖进来时 itemProviders 只有第一个项目：先读拖动剪贴板里的全部文件
        let urls = fileURLs(NSPasteboard(name: .drag))
        if !urls.isEmpty { app.shelf.add(urls); app.shelf.visible = true } else { app.addProvidersToShelf(info.itemProviders(for: [.fileURL])) }
        return true
    }
}

struct ShelfChip: View {
    @EnvironmentObject var app: AppState
    let url: URL
    let remove: () -> Void
    @State var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: ShelfIcons.icon(url)).resizable().frame(width: 16, height: 16)
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                .buttonStyle(.borderless).opacity(hover ? 1 : 0.35).help("从文件架移出（不会改动文件）")
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { app.go(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path + "\n双击在当前栏中显示；拖到文件夹 = 和访达一样的拖放规则")
    }
}

/// 文件架上的图标只取少量（按扩展名 / 文件夹共用），不逐个读取文件内容
enum ShelfIcons {
    static var cache: [String: NSImage] = [:]
    static func icon(_ u: URL) -> NSImage {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        let k = isDir.boolValue ? (u.pathExtension.isEmpty ? "/dir" : "/pkg." + u.pathExtension) : "." + u.pathExtension.lowercased()
        if let i = cache[k] { return i }
        let i: NSImage = isDir.boolValue && u.pathExtension.isEmpty ? genericFolderIcon
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: u.pathExtension) ?? .data)
        cache[k] = i
        return i
    }
}

/// 「拖动全部」把手：一次拖出文件架上的所有项目（多个文件 URL），放下时由目标按访达规则处理
struct ShelfDragAll: NSViewRepresentable {
    let urls: [URL]
    func makeNSView(context: Context) -> ShelfDragView { let v = ShelfDragView(); v.urls = urls; return v }
    func updateNSView(_ v: ShelfDragView, context: Context) { v.urls = urls }
}
final class ShelfDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    private var downAt: NSPoint?
    static let image: NSImage = {
        let i = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖动全部") ?? NSImage()
        return i
    }()
    override func draw(_ r: NSRect) {
        let img = ShelfDragView.image
        let s = NSSize(width: 16, height: 16)
        let rr = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        NSColor.secondaryLabelColor.set()
        img.draw(in: rr)
    }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 3, !urls.isEmpty else { return }
        downAt = nil
        let items = ShelfDragView.draggingItems(urls, from: self)
        beginDraggingSession(with: items, event: e, source: self)
    }
    static func draggingItems(_ urls: [URL], from v: NSView?) -> [NSDraggingItem] {
        urls.enumerated().map { i, u in
            let it = NSDraggingItem(pasteboardWriter: u as NSURL)
            let img = NSWorkspace.shared.icon(forFile: u.path); img.size = NSSize(width: 32, height: 32)
            it.setDraggingFrame(NSRect(x: CGFloat(i % 6) * 6, y: CGFloat(i % 6) * -6, width: 32, height: 32), contents: img)
            return it
        }
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link, .generic] }
}

struct ShelfStatusButton: View {
    @ObservedObject var shelf: ShelfModel
    var body: some View {
        Button { shelf.visible.toggle() } label: {
            HStack(spacing: 3) { Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full"); if !shelf.items.isEmpty { Text("\(shelf.items.count)") } }
        }.buttonStyle(.borderless).help(shelf.visible ? "隐藏文件架" : "显示文件架")
    }
}
