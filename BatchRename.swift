import SwiftUI
import AppKit
import Combine

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

// MARK: - 表单（AppKit）
/// 批量重命名表单用 AppKit 搭建：本机实测 SwiftUI 表单每次打开都要阻塞主线程 141–164ms（只放一行文字的 SwiftUI 表单也要 66ms），
/// 普通 AppKit 表单约 7–14ms。预览列表是只画可见行的表格，没有滚动条。
final class BatchRenamePanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let m: BatchRenameModel
    private weak var app: AppState?
    let window: NSWindow
    private var sub: AnyCancellable?
    private let find = NSTextField(), replace = NSTextField(), prefix = NSTextField(), suffix = NSTextField()
    private let format = NSTextField(), start = NSTextField(), sep = NSTextField()
    private let caseBox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    private let extBox = NSButton(checkboxWithTitle: "保留扩展名", target: nil, action: nil)
    private let mode = NSSegmentedControl(labels: NumberMode.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    private let stepper = NSStepper()
    private let digitsLabel = NSTextField(labelWithString: ""), example = NSTextField(labelWithString: ""), formatLabel = NSTextField(labelWithString: "名称")
    private let startLabel = NSTextField(labelWithString: "起始"), sepLabel = NSTextField(labelWithString: "分隔")
    private let count = NSTextField(labelWithString: ""), hint = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let okButton = NSButton(title: "重命名", target: nil, action: nil), cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var shown: [RenameRow] = [], footer: String?

    init(m: BatchRenameModel, app: AppState) {
        self.m = m; self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build(); refresh()
        // 规则 / 预览结果变化后刷新（objectWillChange 在改值之前发出，所以放到下一轮主线程再读）
        sub = m.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
    }
    func present(on w: NSWindow) {
        window.initialFirstResponder = find
        w.beginSheet(window, completionHandler: nil)
        window.makeFirstResponder(find)
    }
    func close() {
        sub = nil; m.cancel()
        if let p = window.sheetParent { p.endSheet(window) } else { window.orderOut(nil) }
    }
    @objc func cancelAction(_ s: Any?) { app?.batchRename = nil }
    @objc func commitAction(_ s: Any?) {
        guard m.canApply, let app = app else { NSSound.beep(); return }
        let rows = m.rows
        app.batchRename = nil
        app.applyBatchRename(rows)
    }

    // MARK: 搭建（固定位置排版，不用自动布局：本机实测自动布局计算尺寸一项就要约 30ms）
    private func place(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, in c: NSView) { v.frame = NSRect(x: x, y: y, width: w, height: h); c.addSubview(v) }
    private func label(_ s: String, right: Bool = false) -> NSTextField { let l = NSTextField(labelWithString: s); if right { l.alignment = .right }; return l }
    private func setup(_ f: NSTextField, _ ph: String, _ id: String) {
        f.placeholderString = ph; f.delegate = self; f.setAccessibilityIdentifier(id)
        f.cell?.isScrollable = true; f.cell?.wraps = false; f.lineBreakMode = .byClipping
    }
    private func build() {
        let W: CGFloat = 600, L: CGFloat = 20, R: CGFloat = 580, lw: CGFloat = 64, fx = L + lw + 8
        let c = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        var y: CGFloat = 20
        let title = NSTextField(labelWithString: "重新命名 \(m.urls.count) 个项目"); title.font = .boldSystemFont(ofSize: 13)
        place(title, L, y, R - L, 18, in: c); y += 28
        // 一行「标签 输入框 标签 输入框」，两个输入框等宽
        func pair(_ l1: String, _ f1: NSTextField, _ l2: String, _ f2: NSTextField) {
            let a = label(l1, right: true), b = label(l2); b.sizeToFit()
            let fw = (R - fx - 8 - b.frame.width - 8) / 2
            place(a, L, y + 3, lw, 17, in: c)
            place(f1, fx, y, fw, 22, in: c)
            place(b, fx + fw + 8, y + 3, b.frame.width, 17, in: c)
            place(f2, R - fw, y, fw, 22, in: c)
            y += 32
        }
        setup(find, "要替换的文字", "br-find"); setup(replace, "新文字（可留空）", "br-replace")
        pair("查找", find, "替换为", replace)
        for b in [caseBox, extBox] { b.target = self; b.action = #selector(changed(_:)); b.sizeToFit() }
        place(caseBox, fx, y, caseBox.frame.width, 18, in: c)
        place(extBox, fx + caseBox.frame.width + 16, y, extBox.frame.width, 18, in: c); y += 28
        setup(prefix, "加在名称前面", "br-prefix"); setup(suffix, "加在扩展名前面", "br-suffix")
        pair("前缀", prefix, "后缀", suffix)
        place(label("编号", right: true), L, y + 3, lw, 17, in: c)
        mode.target = self; mode.action = #selector(changed(_:)); mode.sizeToFit()
        place(mode, fx, y, mode.frame.width, mode.frame.height, in: c); y += 32
        // 编号细节：名称、起始、位数、分隔、示例
        stepper.minValue = 1; stepper.maxValue = 6; stepper.increment = 1; stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(changed(_:))
        setup(format, "例如：旅行", "br-format"); setup(start, "", "br-start"); setup(sep, "", "br-sep")
        var x = fx
        func lab(_ l: NSTextField, _ w: CGFloat? = nil) { l.sizeToFit(); let ww = w ?? l.frame.width; place(l, x, y + 3, ww, 17, in: c); x += ww + 6 }
        func fld(_ f: NSView, _ w: CGFloat, _ h: CGFloat = 22, dy: CGFloat = 0) { place(f, x, y + dy, w, h, in: c); x += w + 12 }
        lab(formatLabel); fld(format, 110)
        lab(startLabel); fld(start, 60)
        lab(digitsLabel, 46); fld(stepper, 15, 22)
        lab(sepLabel); fld(sep, 40)
        example.textColor = .secondaryLabelColor
        place(example, x, y + 3, max(40, R - x), 17, in: c); y += 34
        let line = NSBox(); line.boxType = .separator
        place(line, L, y, R - L, 1, in: c); y += 10
        let pv = NSTextField(labelWithString: "预览"); pv.font = .systemFont(ofSize: 12, weight: .semibold); pv.sizeToFit()
        place(pv, L, y, pv.frame.width, 17, in: c)
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor; count.alignment = .right
        place(count, L + 200, y + 1, R - L - 200, 16, in: c); y += 24
        // 预览列表：只画可见的行；不显示滚动条（触控板 / 滚轮照常滚动）
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r")); col.width = R - L
        table.addTableColumn(col); table.headerView = nil; table.dataSource = self; table.delegate = self
        table.intercellSpacing = NSSize(width: 0, height: 2); table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none; table.refusesFirstResponder = true
        let sv = NSScrollView(); sv.documentView = table; sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false
        sv.drawsBackground = true; sv.backgroundColor = .textBackgroundColor; sv.borderType = .lineBorder
        place(sv, L, y, R - L, 220, in: c); table.frame.size.width = R - L; y += 228
        hint.font = .systemFont(ofSize: 11); hint.lineBreakMode = .byTruncatingMiddle
        place(hint, L, y, R - L, 16, in: c); y += 26
        cancelButton.target = self; cancelButton.action = #selector(cancelAction(_:)); cancelButton.keyEquivalent = "\u{1b}"
        okButton.target = self; okButton.action = #selector(commitAction(_:)); okButton.keyEquivalent = "\r"
        for b in [cancelButton, okButton] { b.bezelStyle = .rounded; b.sizeToFit(); b.frame.size.width = max(b.frame.width, 84) }
        place(okButton, R - okButton.frame.width, y, okButton.frame.width, okButton.frame.height, in: c)
        place(cancelButton, okButton.frame.minX - 12 - cancelButton.frame.width, y, cancelButton.frame.width, cancelButton.frame.height, in: c)
        y += okButton.frame.height + 20
        c.frame.size.height = y
        window.contentView = c
        window.setContentSize(c.frame.size)
    }

    // MARK: 输入 → 规则
    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        var r = m.rule
        let s = f.stringValue
        if f === find { r.find = s } else if f === replace { r.replace = s } else if f === prefix { r.prefix = s } else if f === suffix { r.suffix = s }
        else if f === format { r.format = s } else if f === sep { r.separator = s }
        else if f === start { if let v = Int(s.trimmingCharacters(in: .whitespaces)) { r.start = v } }
        if r != m.rule { m.rule = r }
    }
    @objc func changed(_ s: Any?) {
        var r = m.rule
        r.caseSensitive = caseBox.state == .on; r.keepExt = extBox.state == .on
        r.numberMode = NumberMode.allCases[max(0, min(NumberMode.allCases.count - 1, mode.selectedSegment))]
        r.digits = max(1, min(6, stepper.integerValue))
        if r != m.rule { m.rule = r }
    }

    // MARK: 规则 / 预览 → 界面
    /// 只在内容真的不同时才写回（用户打字时规则和输入框一致，不会打断输入；规则被程序改动时输入框跟着变）
    private func sync(_ f: NSTextField, _ s: String) { if f.stringValue != s { f.stringValue = s } }
    func refresh() {
        let r = m.rule
        sync(find, r.find); sync(replace, r.replace); sync(prefix, r.prefix); sync(suffix, r.suffix)
        sync(format, r.format); sync(start, String(r.start)); sync(sep, r.separator)
        caseBox.state = r.caseSensitive ? .on : .off; extBox.state = r.keepExt ? .on : .off
        mode.selectedSegment = NumberMode.allCases.firstIndex(of: r.numberMode) ?? 0
        stepper.integerValue = r.digits; digitsLabel.stringValue = "位数 \(r.digits)"
        let on = r.numberMode != .off
        start.isEnabled = on; stepper.isEnabled = on; sep.isEnabled = on; format.isEnabled = r.numberMode == .format
        for (l, e) in [(startLabel, on), (sepLabel, on), (digitsLabel, on), (formatLabel, r.numberMode == .format)] { l.textColor = e ? .labelColor : .disabledControlTextColor }
        example.stringValue = on ? "例：" + BatchRename.number(0, r) : ""
        let blocking = m.blocking
        count.stringValue = m.computing ? "正在计算预览…" : "将改名 \(m.changedCount) 项" + (blocking.isEmpty ? "" : "，\(blocking.count) 项有问题")
        if let b = blocking.first, let msg = b.status.message { hint.stringValue = "无法重命名：“\(b.old)” — \(msg)"; hint.textColor = .systemRed }
        else { hint.stringValue = "扩展名默认保留；可以用 ⌘Z 一次撤销整批改名。"; hint.textColor = .secondaryLabelColor }
        okButton.isEnabled = m.canApply
        let rows = Array(m.rows.prefix(500))
        let foot: String? = m.rows.count > 500 ? "（只预览前 500 项，全部 \(m.rows.count) 项都会按同样规则检查和改名）" : nil
        if rows != shown || foot != footer { shown = rows; footer = foot; table.reloadData() }
    }

    // MARK: 预览列表
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count + (footer == nil ? 0 : 1) }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { row < shown.count && shown[row].status.message != nil ? 34 : 18 }
    func tableView(_ tv: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("brcell")
        let c = (tv.makeView(withIdentifier: id, owner: nil) as? RenamePreviewCell) ?? { let c = RenamePreviewCell(); c.identifier = id; return c }()
        if row < shown.count { c.set(shown[row], nil) } else { c.set(nil, footer) }
        return c
    }
}

/// 预览列表的一行：直接绘制「旧名 → 新名」（有问题时下面再画一行红字），不建子视图
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class RenamePreviewCell: NSView {
    private var row: RenameRow?, note: String?
    func set(_ r: RenameRow?, _ n: String?) { row = r; note = n; needsDisplay = true }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
        let small = NSFont.systemFont(ofSize: 11), f = NSFont.systemFont(ofSize: 12)
        let w = bounds.width - 16
        if let n = note {
            (n as NSString).draw(with: NSRect(x: 8, y: 1, width: w, height: 16), options: [.usesLineFragmentOrigin], attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
            return
        }
        guard let r = row else { return }
        let half = (w - 20) / 2
        (r.old as NSString).draw(with: NSRect(x: 8, y: 1, width: half, height: 16), options: [.usesLineFragmentOrigin], attributes: [.font: f, .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
        ("→" as NSString).draw(at: NSPoint(x: 8 + half + 4, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor])
        let c: NSColor = r.status.isBlocking ? .systemRed : (r.status == .unchanged ? .secondaryLabelColor : .labelColor)
        (r.new as NSString).draw(with: NSRect(x: 8 + half + 20, y: 1, width: half, height: 16), options: [.usesLineFragmentOrigin], attributes: [.font: f, .foregroundColor: c, .paragraphStyle: p])
        if let msg = r.status.message {
            (msg as NSString).draw(with: NSRect(x: 8, y: 18, width: w, height: 15), options: [.usesLineFragmentOrigin], attributes: [.font: small, .foregroundColor: NSColor.systemRed, .paragraphStyle: p])
        }
    }
}
