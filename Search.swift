import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 搜索条件（仿访达：范围栏下方的条件行，可叠加多条）
enum CritField: String, Codable, CaseIterable {
    case name, contents, kind, modified, created, size, tag
    var title: String {
        switch self {
        case .name: return "名称"; case .contents: return "内容"; case .kind: return "种类"
        case .modified: return "上次修改日期"; case .created: return "创建日期"
        case .size: return "大小"; case .tag: return "标签"
        }
    }
    /// (值, 标题) — 只有一个时界面直接显示文字，不给弹出菜单
    var ops: [(String, String)] {
        switch self {
        case .name: return [("contains", "包含"), ("is", "是"), ("begins", "开头是"), ("ends", "结尾是")]
        case .contents: return [("contains", "包含")]
        case .kind, .tag: return [("is", "是")]
        case .modified, .created: return [("within", "在过去"), ("before", "早于"), ("after", "晚于")]
        case .size: return [("bigger", "大于"), ("smaller", "小于")]
        }
    }
}

let kindPresets: [(String, String)] = [
    ("文件夹", "public.folder"), ("图像", "public.image"), ("影片", "public.movie"),
    ("音乐", "public.audio"), ("PDF", "com.adobe.pdf"), ("演示文稿", "public.presentation"),
    ("电子表格", "public.spreadsheet"), ("文本", "public.text"), ("App", "com.apple.application"),
    ("压缩包", "public.archive")]
let sizeUnits: [(String, Double)] = [("KB", 1024), ("MB", 1048576), ("GB", 1073741824)]

struct SearchCriterion: Codable, Equatable, Identifiable {
    var id = UUID()
    var field: CritField = .name
    var op = "contains"
    var text = ""
    var number: Double = 7
    var unit: Double = 1048576
    var date = Date()
    var kind = "public.image"
    /// 切换字段后把运算符和取值重置成该字段的默认值
    mutating func resetForField() {
        op = field.ops[0].0; text = ""
        number = field == .size ? 10 : 7; unit = 1048576; date = Date(); kind = "public.image"
    }
    /// 能交给 Spotlight 的条件都进谓词（结果上限 2000，截断前先过滤才对）；
    /// 「内容」只靠谓词，客户端不重复读文件。
    var spotlight: NSPredicate? {
        switch field {
        case .name:
            guard !text.isEmpty else { return nil }
            switch op {
            case "is": return NSPredicate(format: "kMDItemFSName ==[cd] %@", text)
            case "begins": return NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "\(text)*")
            case "ends": return NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(text)")
            default: return NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(text)*")
            }
        case .contents:
            return text.isEmpty ? nil : NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", text)
        case .kind:
            return NSPredicate(format: "kMDItemContentTypeTree == %@", kind)
        case .modified, .created:
            let a = field == .modified ? "kMDItemFSContentChangeDate" : "kMDItemFSCreationDate"
            switch op {
            case "within": return NSPredicate(format: "\(a) > %@", Date(timeIntervalSinceNow: -number * 86400) as NSDate)
            case "before": return NSPredicate(format: "\(a) < %@", date as NSDate)
            default: return NSPredicate(format: "\(a) > %@", date as NSDate)
            }
        case .size:
            return NSPredicate(format: op == "bigger" ? "kMDItemFSSize > %lld" : "kMDItemFSSize < %lld", Int64(number * unit))
        case .tag:
            return text.isEmpty ? nil : NSPredicate(format: "kMDItemUserTags == %@", text)
        }
    }
}

/// 客户端逐条套用（当前文件夹平铺过滤 + Spotlight 结果再校一遍，与谓词一致）
func matchCriterion(_ it: FileItem, _ c: SearchCriterion, now: Date = Date()) -> Bool {
    switch c.field {
    case .name:
        switch c.op {
        case "is": return it.name.caseInsensitiveCompare(c.text) == .orderedSame
        case "begins": return it.name.range(of: c.text, options: [.caseInsensitive, .anchored]) != nil
        case "ends": return it.name.range(of: c.text, options: [.caseInsensitive, .anchored, .backwards]) != nil
        default: return it.name.localizedCaseInsensitiveContains(c.text)
        }
    case .contents: return true   // 已由 Spotlight 谓词承担
    case .kind:
        if it.isFolderLike { return c.kind == "public.folder" }
        guard let want = UTType(c.kind) else { return false }
        // UTI 按需推导：种类条件很少用，不值得让 FileItem 常驻一个字段（1000 项刷新实测慢约 9ms）
        let t = UTType(filenameExtension: it.url.pathExtension)
            ?? (try? it.url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        return t?.conforms(to: want) ?? false
    case .modified, .created:
        guard let d = c.field == .modified ? it.modified : it.created else { return false }
        switch c.op {
        case "within": return d > now.addingTimeInterval(-c.number * 86400)
        case "before": return d < c.date
        default: return d > c.date
        }
    case .size:
        let b = Int64(c.number * c.unit)
        return c.op == "bigger" ? it.size > b : it.size < b
    case .tag:
        return it.tags.contains(c.text)
    }
}

// MARK: - 已存搜索（仿访达「存储」智能文件夹：保存在侧栏，点开重跑）
struct SavedSearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var scope: SearchScope
    var matchMode: SearchMatch
    var criteria: [SearchCriterion]
}

#if FB_TESTING
var promptTextOverride: String?
#endif

/// 简单的文字输入对话框（存储搜索、重命名已存搜索、保存布局、重命名置顶文件夹）
func promptText(title: String, message: String, initial: String = "") -> String? {
    #if FB_TESTING
    if let o = promptTextOverride { return o.trimmingCharacters(in: .whitespaces) }
    if TestEnv.active { return initial.trimmingCharacters(in: .whitespaces) }
    #endif
    let a = NSAlert()
    a.messageText = title; a.informativeText = message
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    f.stringValue = initial; f.placeholderString = initial
    a.accessoryView = f
    a.addButton(withTitle: "好"); a.addButton(withTitle: "取消")
    a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespaces) : nil
}

// MARK: - 搜索建议（仿访达：输入时下拉「名称匹配 / 内容包含 / 最近的搜索」）
struct SuggItem: Identifiable {
    enum Kind { case nameMatch, contentsMatch, recent }
    let id = UUID()
    let kind: Kind
    let title: String
    let query: String
}

final class SuggState: ObservableObject {
    @Published var items: [SuggItem] = []
    @Published var sel = 0
}

struct SuggestionsView: View {
    @ObservedObject var state: SuggState
    let pick: (SuggItem) -> Void
    var body: some View {
        let tokens = state.items.filter { $0.kind != .recent }
        let recs = state.items.filter { $0.kind == .recent }
        VStack(alignment: .leading, spacing: 0) {
            if !tokens.isEmpty { section("建议"); rows(tokens) }
            if !recs.isEmpty { section("最近的搜索"); rows(recs) }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 184, maxWidth: 280)
        .background(.regularMaterial)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
    func section(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 3)
    }
    func rows(_ list: [SuggItem]) -> some View {
        ForEach(list) { item in
            let i = state.items.firstIndex(where: { $0.id == item.id }) ?? -1
            Button { pick(item) } label: {
                HStack(spacing: 7) {
                    Image(systemName: item.kind == .recent ? "clock" : "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(i == state.sel ? Color.accentColor.opacity(0.85) : .clear)
                .foregroundStyle(i == state.sel ? .white : .primary)
                .cornerRadius(4).padding(.horizontal, 5)
            }.buttonStyle(.plain)
        }
    }
}

/// 访达式建议下拉：一个不抢焦点的浮窗，键盘事件仍进搜索框（方向键/回车/Esc 由本地监视器转给面板）
final class SearchSuggestions {
    static let shared = SearchSuggestions()
    let state = SuggState()
    private var panel: NSPanel?
    private var keyMon: Any?, mouseMon: Any?
    private var obs: [NSObjectProtocol] = []
    private weak var field: NSTextField?
    var onPick: ((SuggItem) -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(anchor tf: NSTextField, text: String, recents: [String], pick: @escaping (SuggItem) -> Void) {
        var items: [SuggItem] = []
        if !text.isEmpty {
            items.append(SuggItem(kind: .nameMatch, title: "名称匹配「\(text)」", query: text))
            items.append(SuggItem(kind: .contentsMatch, title: "内容包含「\(text)」", query: text))
        }
        items += recents.filter { $0 != text && (text.isEmpty || $0.localizedCaseInsensitiveContains(text)) }
            .prefix(5).map { SuggItem(kind: .recent, title: $0, query: $0) }
        guard !items.isEmpty, let win = tf.window else { hide(); return }
        field = tf; onPick = pick
        state.items = items
        if state.sel >= items.count || state.sel < 0 { state.sel = 0 }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .floating; p.hasShadow = true
            p.backgroundColor = .clear; p.isOpaque = false
            p.contentView = NSHostingView(rootView: SuggestionsView(state: state) { [weak self] in self?.accept($0) })
            panel = p
        }
        let host = panel!.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let tfRect = win.convertToScreen(tf.convert(tf.bounds, to: nil))
        let w = max(size.width, min(tfRect.width + 26, 220))
        // 右侧与搜索框外框对齐（且不超出当前窗口右边界与屏幕右边界），避免浮窗往右穿出窗口
        let boxMaxX = min(tfRect.maxX + 10, win.frame.maxX - 10)
        let screenMaxX = (win.screen ?? NSScreen.main)?.visibleFrame.maxX ?? .greatestFiniteMagnitude
        var x = min(tfRect.minX - 18, min(boxMaxX - w, screenMaxX - w - 8))
        x = max(x, (win.screen ?? NSScreen.main)?.visibleFrame.minX ?? x)
        panel!.setFrame(NSRect(x: x, y: tfRect.minY - size.height - 6, width: w, height: size.height), display: true)
        if panel!.parent !== win { panel!.parent?.removeChildWindow(panel!); win.addChildWindow(panel!, ordered: .above) }
        if !panel!.isVisible { panel!.orderFront(nil) }
        installMonitors()
        observeField(tf)
    }

    func hide() {
        panel?.parent?.removeChildWindow(panel!); panel?.orderOut(nil)
        field = nil; onPick = nil; state.sel = 0
        if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        if let m = mouseMon { NSEvent.removeMonitor(m); mouseMon = nil }
        obs.forEach { NotificationCenter.default.removeObserver($0) }; obs = []
    }

    private func accept(_ item: SuggItem) {
        let cb = onPick; hide(); cb?(item)
    }

    private func move(_ d: Int) {
        guard !state.items.isEmpty else { return }
        state.sel = (state.sel + d + state.items.count) % state.items.count
    }

    private func installMonitors() {
        guard keyMon == nil else { return }
        keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isVisible, let f = self.field,
                  e.window === f.window, (f.window?.firstResponder as? NSTextView)?.delegate === f else { return e }
            switch e.keyCode {
            case 125: self.move(1); return nil
            case 126: self.move(-1); return nil
            case 36, 76: if self.state.sel < self.state.items.count { self.accept(self.state.items[self.state.sel]) }; return nil
            case 53: self.hide(); return nil
            default: return e
            }
        }
        mouseMon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, self.isVisible, e.window !== self.panel { self.hide() }
            return e
        }
    }

    private func observeField(_ tf: NSTextField) {
        obs.forEach { NotificationCenter.default.removeObserver($0) }; obs = []
        let nc = NotificationCenter.default
        obs.append(nc.addObserver(forName: NSControl.textDidEndEditingNotification, object: tf, queue: .main) { [weak self] _ in self?.hide() })
        obs.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: tf.window, queue: .main) { [weak self] _ in self?.hide() })
    }
}

/// 工具栏搜索框对应的 NSTextField（焦点与建议面板定位用）
func searchField(in w: NSWindow) -> NSTextField? {
    func find(_ v: NSView) -> NSTextField? {
        if let t = v as? NSTextField, t.isEditable, t.window != nil, (t.placeholderString ?? t.placeholderAttributedString?.string) == "搜索" { return t }
        for s in v.subviews { if let f = find(s) { return f } }
        return nil
    }
    let roots = [w.contentView?.superview].compactMap { $0 } + (w.toolbar?.items.compactMap { $0.view } ?? [])
    return roots.lazy.compactMap(find).first
}
