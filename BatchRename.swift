import SwiftUI
import AppKit

// MARK: - v0.6 批量重命名：替换文字、加前缀 / 后缀、按序号编号；改名前预览，冲突和无效名称先拦下；整批一次 ⌘Z 撤销

/// 线程安全的取消标记（命令面板搜索、批量重命名预览共用）
final class CancelToken {
    private let l = NSLock(); private var c = false
    var isCancelled: Bool { l.lock(); defer { l.unlock() }; return c }
    func cancel() { l.lock(); c = true; l.unlock() }
}

enum NumberMode: String, CaseIterable {
    case off, suffix, format
    var title: String { switch self { case .off: return "不编号"; case .suffix: return "名称后加序号"; case .format: return "统一名称 + 序号" } }
}

struct RenameRule: Equatable {
    var find = "", replace = "", caseSensitive = false
    var prefix = "", suffix = ""
    var numberMode: NumberMode = .off
    var format = "文件"
    var start = 1, digits = 1
    var separator = " "
    var keepExt = true
}

enum RenameStatus: Equatable {
    case unchanged, ok, invalid(String), conflict(String)
    var isBlocking: Bool { switch self { case .invalid, .conflict: return true; default: return false } }
    var message: String? { switch self { case .invalid(let m), .conflict(let m): return m; default: return nil } }
}

struct RenameRow: Identifiable, Equatable {
    let id: Int
    let src: URL
    let old: String
    let new: String
    let status: RenameStatus
    var dst: URL { src.deletingLastPathComponent().appendingPathComponent(new) }
}

enum BatchRename {
    /// 拆成「主名 + 扩展名」。文件夹、没有扩展名、以「.」开头的名称（.bashrc）都不拆。包（.app 等）当作文件，保留扩展名。
    static func split(_ name: String, folderLike: Bool, keepExt: Bool) -> (base: String, ext: String) {
        guard keepExt, !folderLike else { return (name, "") }
        let ns = name as NSString, ext = ns.pathExtension, base = ns.deletingPathExtension
        if ext.isEmpty || base.isEmpty { return (name, "") }
        return (base, ext)
    }
    static func number(_ i: Int, _ r: RenameRule) -> String {
        let n = max(0, min(r.start, 999_999)) + i, d = max(1, min(r.digits, 6))
        let s = String(n)
        return s.count >= d ? s : String(repeating: "0", count: d - s.count) + s
    }
    /// 第 index 个项目（按所选顺序，从 0 开始）按规则得到的新名字
    static func newName(_ name: String, folderLike: Bool, index: Int, rule r: RenameRule) -> String {
        var (base, ext) = split(name, folderLike: folderLike, keepExt: r.keepExt)
        if !r.find.isEmpty { base = base.replacingOccurrences(of: r.find, with: r.replace, options: r.caseSensitive ? [] : [.caseInsensitive]) }
        switch r.numberMode {
        case .off: break
        case .suffix: base += r.separator + number(index, r)
        case .format: base = r.format.isEmpty ? number(index, r) : r.format + r.separator + number(index, r)
        }
        base = r.prefix + base + r.suffix
        return ext.isEmpty ? base : base + "." + ext
    }
    /// 名称本身是否可用（访达的说法）；nil = 可用
    static func validate(_ n: String) -> String? {
        if n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "名称不能为空。" }
        if n.contains("/") || n.contains(":") { return "名称不能包含“/”或“:”。" }
        if n.hasPrefix(".") { return "以“.”开头的名称是系统保留的（会让项目隐藏）。请选取一个不同的名称。" }
        if n.utf8.count > 255 { return "名称“\(n.prefix(20))…”太长。" }
        return nil
    }
    /// APFS / HFS+ 默认不区分大小写、不区分 Unicode 组合方式：比较用的键
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// 生成预览：每一项的新名字和状态。exists 可注入（测试用）。
    static func plan(_ items: [(url: URL, folderLike: Bool)], rule: RenameRule,
                     exists: (String) -> Bool = { FileOps.lexists($0) }, cancelled: () -> Bool = { false }) -> [RenameRow] {
        var names: [String] = []; names.reserveCapacity(items.count)
        for (i, it) in items.enumerated() {
            if i % 512 == 0 && cancelled() { return [] }
            names.append(newName(it.url.lastPathComponent, folderLike: it.folderLike, index: i, rule: rule))
        }
        let srcKeys = Set(items.map { key($0.url.standardizedFileURL.path) })
        var count: [String: Int] = [:]
        var targetKeys: [String] = []
        for (i, it) in items.enumerated() {
            let k = key(it.url.deletingLastPathComponent().standardizedFileURL.path + "/" + names[i])
            targetKeys.append(k); count[k, default: 0] += 1
        }
        var rows: [RenameRow] = []; rows.reserveCapacity(items.count)
        for (i, it) in items.enumerated() {
            if i % 256 == 0 && cancelled() { return [] }
            let old = it.url.lastPathComponent, new = names[i]
            let st: RenameStatus
            if new == old { st = count[targetKeys[i]]! > 1 ? .conflict("有 \(count[targetKeys[i]]!) 个项目会得到同一个名称“\(new)”。") : .unchanged }
            else if let bad = validate(new) { st = .invalid(bad) }
            else if count[targetKeys[i]]! > 1 { st = .conflict("有 \(count[targetKeys[i]]!) 个项目会得到同一个名称“\(new)”。") }
            else if !srcKeys.contains(targetKeys[i]) && exists(it.url.deletingLastPathComponent().appendingPathComponent(new).path) {
                st = .conflict("名称“\(new)”已被使用。请选取一个不同的名称。")
            } else { st = .ok }
            rows.append(RenameRow(id: i, src: it.url, old: old, new: new, status: st))
        }
        return rows
    }

    private static func err(_ e: Int32, _ name: String) -> Error {
        if e == EEXIST || e == ENOTEMPTY { return FBError("名称“\(name)”已被使用。请选取一个不同的名称。") }
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        if e == EACCES || e == EPERM {
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "没有权限重命名“\(name)”。", NSUnderlyingErrorKey: posix])
        }
        return FBError("「\(name)」：\(String(cString: strerror(e)))")
    }
    /// 两步改名：先全部改成临时名，再改成目标名。这样 a↔b 互换、只改大小写、链式改名都不会互相覆盖。
    /// 任何一步失败都会把已经改过的全部改回原名，然后报错（不会只改一半）。目标名已被占用时绝不覆盖（RENAME_EXCL）。
    static func twoPhaseMove(_ moves: [(URL, URL)], progress: OpProgress? = nil) throws {
        let tag = UUID().uuidString.prefix(8)
        var temps: [(src: URL, tmp: URL, dst: URL)] = []
        func undoTemps() { for t in temps.reversed() { _ = renamex_np(t.tmp.path, t.src.path, UInt32(RENAME_EXCL)) } }
        for (i, m) in moves.enumerated() {
            let tmp = m.0.deletingLastPathComponent().appendingPathComponent(".fb-rename-\(tag)-\(i)")
            if renamex_np(m.0.path, tmp.path, UInt32(RENAME_EXCL)) != 0 { let e = errno; undoTemps(); throw err(e, m.0.lastPathComponent) }
            temps.append((m.0, tmp, m.1))
        }
        var done: [Int] = []
        for (i, t) in temps.enumerated() {
            if renamex_np(t.tmp.path, t.dst.path, UInt32(RENAME_EXCL)) != 0 {
                let e = errno
                for j in done.reversed() { _ = renamex_np(temps[j].dst.path, temps[j].tmp.path, UInt32(RENAME_EXCL)) }
                undoTemps()
                throw err(e, t.dst.lastPathComponent)
            }
            done.append(i); progress?.step()
        }
    }
    /// 执行预览里状态为「可以改名」的项目；有任何冲突 / 无效名称时拒绝执行。返回 (原位置, 新位置)。
    static func apply(_ rows: [RenameRow], progress: OpProgress? = nil) throws -> [(URL, URL)] {
        if let bad = rows.first(where: { $0.status.isBlocking }) { throw FBError(bad.status.message ?? "名称无效。") }
        let pairs = rows.filter { $0.status == .ok }.map { ($0.src, $0.dst) }
        guard !pairs.isEmpty else { return [] }
        try twoPhaseMove(pairs, progress: progress)
        return pairs
    }
    static func undo(_ pairs: [(URL, URL)]) throws { try twoPhaseMove(pairs.map { ($0.1, $0.0) }) }
}

/// 批量重命名窗口的状态。预览在后台计算（几千个项目也不卡），规则一变就取消上一轮。
final class BatchRenameModel: ObservableObject, Identifiable {
    let id = UUID()
    let urls: [URL]
    @Published var rule = RenameRule() { didSet { if rule != oldValue { schedule() } } }
    @Published private(set) var rows: [RenameRow] = []
    @Published private(set) var computing = true
    private var folderLike: [Bool]?
    private var token = CancelToken()
    private let queue = DispatchQueue(label: "filebutler.batchrename", qos: .userInitiated)
    init(urls: [URL]) { self.urls = urls; schedule() }
    deinit { token.cancel() }
    var changedCount: Int { rows.filter { $0.status == .ok }.count }
    var blocking: [RenameRow] { rows.filter { $0.status.isBlocking } }
    var canApply: Bool { !computing && changedCount > 0 && blocking.isEmpty }
    func cancel() { token.cancel() }
    func schedule() {
        token.cancel(); let tok = CancelToken(); token = tok
        computing = true
        let urls = self.urls, rule = self.rule, known = folderLike
        queue.async { [weak self] in
            let fl = known ?? urls.map { u -> Bool in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            }
            if tok.isCancelled { return }
            let rows = BatchRename.plan(Array(zip(urls, fl)).map { (url: $0.0, folderLike: $0.1) }, rule: rule, cancelled: { tok.isCancelled })
            DispatchQueue.main.async {
                guard let self = self, !tok.isCancelled else { return }
                self.folderLike = fl
                self.rows = rows; self.computing = false
            }
        }
    }
}

struct BatchRenameSheet: View {
    @ObservedObject var m: BatchRenameModel
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let labelW: CGFloat = 64
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重新命名 \(m.urls.count) 个项目").font(.headline)
            HStack {
                Text("查找").frame(width: labelW, alignment: .trailing)
                TextField("要替换的文字", text: $m.rule.find).accessibilityIdentifier("br-find")
                Text("替换为")
                TextField("新文字（可留空）", text: $m.rule.replace).accessibilityIdentifier("br-replace")
            }
            HStack {
                Spacer().frame(width: labelW)
                Toggle("区分大小写", isOn: $m.rule.caseSensitive).toggleStyle(.checkbox)
                Toggle("保留扩展名", isOn: $m.rule.keepExt).toggleStyle(.checkbox)
            }
            HStack {
                Text("前缀").frame(width: labelW, alignment: .trailing)
                TextField("加在名称前面", text: $m.rule.prefix)
                Text("后缀")
                TextField("加在扩展名前面", text: $m.rule.suffix)
            }
            HStack {
                Text("编号").frame(width: labelW, alignment: .trailing)
                Picker("", selection: $m.rule.numberMode) { ForEach(NumberMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if m.rule.numberMode != .off {
                HStack(spacing: 8) {
                    Spacer().frame(width: labelW)
                    if m.rule.numberMode == .format {
                        Text("名称"); TextField("例如：旅行", text: $m.rule.format).frame(width: 110)
                    }
                    Text("起始"); TextField("", value: $m.rule.start, format: .number).frame(width: 60)
                    Stepper("位数 \(m.rule.digits)", value: $m.rule.digits, in: 1...6).fixedSize()
                    Text("分隔"); TextField("", text: $m.rule.separator).frame(width: 40)
                    Text("例：" + BatchRename.number(0, m.rule)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("预览").font(.subheadline.weight(.semibold))
                if m.computing { ProgressView().controlSize(.small) }
                Spacer()
                Text("将改名 \(m.changedCount) 项" + (m.blocking.isEmpty ? "" : "，\(m.blocking.count) 项有问题")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(m.rows.prefix(500)) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(r.old).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(r.new).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(r.status.isBlocking ? AnyShapeStyle(Color.red) : (r.status == .unchanged ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                            }.font(.system(size: 12))
                            if let msg = r.status.message { Text(msg).font(.system(size: 11)).foregroundStyle(.red) }
                        }
                    }
                    if m.rows.count > 500 { Text("（只预览前 500 项，全部 \(m.rows.count) 项都会按同样规则检查和改名）").font(.caption).foregroundStyle(.secondary) }
                }.padding(8)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            if let b = m.blocking.first, let msg = b.status.message {
                Text("无法重命名：“\(b.old)” — \(msg)").font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("扩展名默认保留；可以用 ⌘Z 一次撤销整批改名。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { m.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("重命名") { commit() }.keyboardShortcut(.defaultAction).disabled(!m.canApply)
            }
        }
        .padding(20).frame(width: 600)
    }
    func commit() {
        guard m.canApply else { NSSound.beep(); return }
        let rows = m.rows
        dismiss()
        DispatchQueue.main.async { app.batchRename = nil; app.applyBatchRename(rows) }
    }
}
