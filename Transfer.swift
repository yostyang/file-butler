import AppKit
import Foundation

// MARK: - 后台文件操作：进度、取消、同名冲突（访达行为）

/// 一次文件操作的进度，后台线程写、主线程读
final class OpProgress {
    private let lock = NSLock()
    private var _done = 0, _total = 0, _cancelled = false
    var verb = "拷贝"
    /// 本次操作还剩多少个同名冲突（决定冲突对话框是否显示「应用到全部」）
    var conflictsLeft: Int { get { lock.lock(); defer { lock.unlock() }; return _conflicts } set { lock.lock(); _conflicts = newValue; lock.unlock() } }
    private var _conflicts = 0
    var done: Int { lock.lock(); defer { lock.unlock() }; return _done }
    var total: Int { get { lock.lock(); defer { lock.unlock() }; return _total } set { lock.lock(); _total = newValue; lock.unlock() } }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func step() { lock.lock(); _done += 1; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

enum Conflict { case replace, keepBoth, skip, stop }

struct TransferResult {
    var moved: [(URL, URL)] = []
    var copied: [URL] = []
    var replaced: [(URL, URL)] = []   // 被替换的旧项目 → 废纸篓中的位置（可撤销）
    var errs: [String] = []
    var cancelled = false
}

/// 拷贝回调：每个文件拷贝前检查是否已取消（copyfile 的 C 回调不能捕获变量，通过 ctx 传入进度对象）
private func copyCallback(_ what: Int32, _ stage: Int32, _ state: copyfile_state_t?, _ src: UnsafePointer<CChar>?, _ dst: UnsafePointer<CChar>?, _ ctx: UnsafeMutableRawPointer?) -> Int32 {
    guard let ctx = ctx else { return COPYFILE_CONTINUE }
    let p = Unmanaged<OpProgress>.fromOpaque(ctx).takeUnretainedValue()
    return p.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
}

extension FileOps {
    /// APFS 上用 clonefile（瞬间完成、不占额外空间），其他卷自动退回普通拷贝；可取消
    static func copyItem(_ src: URL, to dst: URL, progress: OpProgress?) throws {
        let st = copyfile_state_alloc(); defer { copyfile_state_free(st) }
        let cb: copyfile_callback_t = copyCallback
        let p = progress ?? OpProgress()
        let ctx = Unmanaged.passUnretained(p).toOpaque()
        copyfile_state_set(st, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        copyfile_state_set(st, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        let r = withExtendedLifetime(p) { copyfile(src.path, dst.path, st, flags) }
        if r != 0 {
            let e = errno
            try? fm.removeItem(at: dst)
            if p.isCancelled { throw FBError("已取消") }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(e))])
        }
    }

    /// 访达规则：同一卷默认移动，跨卷默认拷贝；拷贝到原文件夹 = 「副本」；目标已有同名项目时询问（替换 / 保留两者 / 停止）
    /// 分两步：先按顺序逐项规划目标位置（冲突询问、替换都在这一步，和访达一样按顺序问），
    /// 再执行：同卷移动直接 rename(2)；拷贝用 clonefile/copyfile 4 路并行。
    static func transfer(_ urls: [URL], to rawDir: URL, mode: TransferMode, progress: OpProgress? = nil,
                         resolve: ((String, Bool) -> (Conflict, Bool))? = nil) -> TransferResult {
        let dir = rawDir.standardizedFileURL
        var res = TransferResult()
        var sticky: Conflict?
        var volCache: [String: Bool] = [:]
        var reserved = Set<String>()          // 本批次已占用的目标名（避免两项落到同一个名字）
        func taken(_ u: URL) -> Bool { reserved.contains(u.path) || lexists(u.path) }
        func unique(_ name: String, copy: Bool) -> URL { uniqueURL(in: dir, name: name, copy: copy, taken: taken) }
        progress?.total = urls.count
        // 先数一遍会冲突的项目（只用 lstat，很快）
        if resolve != nil {
            var n = 0
            for raw in urls where raw.deletingLastPathComponent().standardizedFileURL.path != dir.path && lexists(dir.appendingPathComponent(raw.lastPathComponent).path) { n += 1 }
            progress?.conflictsLeft = n
        }
        var plan: [(src: URL, dst: URL, move: Bool)] = []
        plan.reserveCapacity(urls.count)
        loop: for raw in urls {
            if progress?.isCancelled == true { res.cancelled = true; break }
            let src = raw.standardizedFileURL, name = src.lastPathComponent
            let parent = src.deletingLastPathComponent().path
            if dir.path == src.path || dir.path.hasPrefix(src.path + "/") { res.errs.append("不能把「\(name)」放进它自身或它的子文件夹。"); progress?.step(); continue }
            var move = mode == .move
            if mode == .auto {
                if let v = volCache[parent] { move = v } else { move = sameVolume(src, dir); volCache[parent] = move }
            }
            let sameDir = parent == dir.path
            if move && sameDir { progress?.step(); continue }
            var dst = dir.appendingPathComponent(name)
            if !move && sameDir { dst = unique(name, copy: true) }
            else if taken(dst) {
                let c: Conflict
                if let s = sticky { c = s }
                else if let r = resolve { let (cc, all) = r(name, move); c = cc; if all { sticky = cc } }
                else { c = .keepBoth }
                if let p = progress { p.conflictsLeft = max(0, p.conflictsLeft - 1) }
                switch c {
                case .stop: res.cancelled = true; break loop
                case .skip: progress?.step(); continue
                case .keepBoth: dst = unique(name, copy: false)
                case .replace:
                    if reserved.contains(dst.path) { dst = unique(name, copy: false) }   // 和本批次另一项同名：保留两者
                    else {
                        do { var out: NSURL?; try fm.trashItem(at: dst, resultingItemURL: &out); if let o = out as URL? { res.replaced.append((dst, o)) } }
                        catch { res.errs.append("「\(name)」：无法替换已有项目（\(error.localizedDescription)）"); progress?.step(); continue }
                    }
                }
            }
            reserved.insert(dst.path)
            plan.append((src, dst, move))
        }
        // 执行：移动（同卷 rename，失败或跨卷时交给 FileManager）
        let moves = plan.filter { $0.move }, copies = plan.filter { !$0.move }
        for m in moves {
            if progress?.isCancelled == true { res.cancelled = true; break }
            defer { progress?.step() }
            if renamex_np(m.src.path, m.dst.path, UInt32(RENAME_EXCL)) == 0 { res.moved.append((m.src, m.dst)); continue }
            do { try fm.moveItem(at: m.src, to: m.dst); res.moved.append((m.src, m.dst)) }
            catch { res.errs.append("「\(m.src.lastPathComponent)」：\(error.localizedDescription)") }
        }
        // 执行：拷贝（4 路并行；结果按原顺序汇总）
        if !copies.isEmpty && !res.cancelled {
            var out = [String?](repeating: nil, count: copies.count)   // nil = 成功，否则为错误信息
            var ran = [Bool](repeating: false, count: copies.count)
            let lock = NSLock(); var next = 0
            let workers = min(4, copies.count)
            out.withUnsafeMutableBufferPointer { ob in ran.withUnsafeMutableBufferPointer { rb in
                let o = ob, r = rb
                DispatchQueue.concurrentPerform(iterations: workers) { _ in
                    while true {
                        lock.lock(); let i = next; next += 1; lock.unlock()
                        if i >= copies.count || progress?.isCancelled == true { return }
                        let c = copies[i]
                        do { try copyItem(c.src, to: c.dst, progress: progress) } catch { o[i] = "「\(c.src.lastPathComponent)」：\(error.localizedDescription)" }
                        r[i] = true
                        progress?.step()
                    }
                }
            } }
            for (i, c) in copies.enumerated() where ran[i] {
                if let e = out[i] { if progress?.isCancelled != true { res.errs.append(e) } } else { res.copied.append(c.dst) }
            }
            if progress?.isCancelled == true { res.cancelled = true }
        }
        return res
    }
    static func lexists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }
    static func isSymlink(_ u: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil }

    /// 访达的 ⌥⌘ 拖放：在目标文件夹里制作替身（名称和原项目相同，重名时自动编号）
    static func makeAlias(_ u: URL, in dir: URL) throws -> URL {
        let data = try u.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        let dst = uniqueURL(in: dir, name: u.lastPathComponent, copy: false)
        try URL.writeBookmarkData(data, to: dst)
        return dst
    }
}

// MARK: - 拖放规则（左右栏、侧边栏、路径栏、访达都走这里）
enum DragMods {
    /// 测试时注入修饰键；平时读取真实键盘状态
    static var override: NSEvent.ModifierFlags?
    static var current: NSEvent.ModifierFlags { (override ?? NSEvent.modifierFlags).intersection([.command, .option, .shift, .control]) }
}
enum DropKind { case none, move, copy, alias
    var op: NSDragOperation { switch self { case .none: return []; case .move: return .move; case .copy: return .copy; case .alias: return .link } }
}
/// 访达：同一卷默认移动、跨卷默认拷贝；⌥ 拷贝；⌘ 移动；⌥⌘ 替身。拖回原文件夹、拖进自身无效。
func planDrop(_ urls: [URL], to target: URL) -> DropKind {
    guard let first = urls.first else { return .none }
    let t = target.standardizedFileURL.path
    if urls.contains(where: { let p = $0.standardizedFileURL.path; return p == t || t.hasPrefix(p + "/") }) { return .none }
    let f = DragMods.current
    if f.contains(.option) && f.contains(.command) { return .alias }
    if f.contains(.option) { return .copy }
    let move = f.contains(.command) || sameVolume(first, target)
    if move && urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == t }) { return .none }
    return move ? .move : .copy
}
func fileURLs(_ pb: NSPasteboard) -> [URL] {
    pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

// MARK: - 活动栏跟随鼠标
enum PaneFocus {
    /// 窗口坐标 → 这一点所在的栏（按横向范围判断，标签栏、路径栏、内容区都算）
    static func pane(at p: NSPoint, in w: NSWindow, app: AppState) -> Int? {
        for i in 0..<(app.dual ? 2 : 1) {
            guard let v = app.responders[i].v, v.window === w, !v.isHiddenOrHasHiddenAncestor else { continue }
            let box = (v is FBKeyView ? v : (v.enclosingScrollView ?? v))
            let r = box.convert(box.bounds, to: nil)
            if p.x >= r.minX && p.x < r.maxX && p.y >= r.minY - 2 && p.y <= r.maxY + 70 { return i }
        }
        return nil
    }
    /// 正在输入（就地重命名、搜索框、路径输入）时不抢焦点
    static func isEditingText(_ w: NSWindow) -> Bool { w.firstResponder is NSTextView }
    static func follow(_ e: NSEvent, app: AppState) {
        guard app.dual, let w = e.window ?? NSApp.keyWindow, w.attachedSheet == nil else { return }
        if e.type == .mouseMoved && NSEvent.pressedMouseButtons != 0 { return }
        let p = e.type == .keyDown ? w.mouseLocationOutsideOfEventStream : e.locationInWindow
        guard let i = pane(at: p, in: w, app: app), i != app.active || (e.type != .mouseMoved && w.firstResponder !== app.responders[i].v) else { return }
        if isEditingText(w) { return }
        app.active = i
        if let v = app.responders[i].v, w.firstResponder !== v { w.makeFirstResponder(v) }
    }
}

// MARK: - 测试与基准：主线程卡顿探针
/// 后台线程每 5ms 往主线程投递一次，记录「投递 → 执行」的最大延迟 = 主线程最长阻塞
final class MainThreadProbe {
    private var running = true
    private let lock = NSLock()
    private(set) var maxGapMs = 0.0
    private var samples: [Double] = []
    func start() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let r = running; lock.unlock()
                if !r { break }
                let t0 = CFAbsoluteTimeGetCurrent()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { let d = (CFAbsoluteTimeGetCurrent() - t0) * 1000; self.lock.lock(); self.samples.append(d); if d > self.maxGapMs { self.maxGapMs = d }; self.lock.unlock(); sem.signal() }
                sem.wait()
                usleep(5000)
            }
        }
    }
    func stop() -> (max: Double, p99: Double, n: Int) {
        lock.lock(); running = false; let s = samples.sorted(); let m = maxGapMs; lock.unlock()
        let p99 = s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.99))]
        return (m, p99, s.count)
    }
}

/// 把拖放类型换成拖放源允许的操作（按住 ⌘ 时系统只给 generic）
func dragOperation(_ kind: DropKind, _ info: NSDraggingInfo) -> NSDragOperation {
    let op = kind.op, m = info.draggingSourceOperationMask
    if kind == .none { return [] }
    if m.contains(op) { return op }
    if m.contains(.generic) { return .generic }
    return op
}

/// 文件夹显示名缓存：路径栏、标签页标题每次刷新都要用，直接查询会走 LaunchServices 读磁盘
private var displayNameCache: [String: String] = [:]
func cachedDisplayName(_ path: String) -> String {
    if let n = displayNameCache[path] { return n }
    let n = FileManager.default.displayName(atPath: path)
    if displayNameCache.count > 2000 { displayNameCache.removeAll() }
    displayNameCache[path] = n
    return n
}
func resetDisplayNames() { displayNameCache.removeAll() }
