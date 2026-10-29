import AppKit
import Foundation

// MARK: - 后台文件操作：进度、取消、同名冲突（访达行为）

/// 一次文件操作的进度，后台线程写、主线程读
final class OpProgress {
    private let lock = NSLock()
    private var _done = 0, _total = 0, _cancelled = false
    var verb = "拷贝"
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
    static func transfer(_ urls: [URL], to rawDir: URL, mode: TransferMode, progress: OpProgress? = nil,
                         resolve: ((String, Bool) -> (Conflict, Bool))? = nil) -> TransferResult {
        let dir = rawDir.standardizedFileURL
        var res = TransferResult()
        var sticky: Conflict?
        var volCache: [String: Bool] = [:]
        progress?.total = urls.count
        loop: for raw in urls {
            if progress?.isCancelled == true { res.cancelled = true; break }
            defer { progress?.step() }
            let src = raw.standardizedFileURL, name = src.lastPathComponent
            let parent = src.deletingLastPathComponent().path
            if dir.path == src.path || dir.path.hasPrefix(src.path + "/") { res.errs.append("不能把「\(name)」放进它自身或它的子文件夹。"); continue }
            var move = mode == .move
            if mode == .auto {
                if let v = volCache[parent] { move = v } else { move = sameVolume(src, dir); volCache[parent] = move }
            }
            let sameDir = parent == dir.path
            if move && sameDir { continue }
            var dst = dir.appendingPathComponent(name)
            if !move && sameDir { dst = uniqueURL(in: dir, name: name, copy: true) }
            else if fm.fileExists(atPath: dst.path) || (try? dst.checkResourceIsReachable()) == true || isSymlink(dst) {
                let c: Conflict
                if let s = sticky { c = s }
                else if let r = resolve { let (cc, all) = r(name, move); c = cc; if all { sticky = cc } }
                else { c = .keepBoth }
                switch c {
                case .stop: res.cancelled = true; break loop
                case .skip: continue
                case .keepBoth: dst = uniqueURL(in: dir, name: name, copy: false)
                case .replace:
                    do { var out: NSURL?; try fm.trashItem(at: dst, resultingItemURL: &out); if let o = out as URL? { res.replaced.append((dst, o)) } }
                    catch { res.errs.append("「\(name)」：无法替换已有项目（\(error.localizedDescription)）"); continue }
                }
            }
            do {
                if move { try fm.moveItem(at: src, to: dst); res.moved.append((src, dst)) }
                else { try copyItem(src, to: dst, progress: progress); res.copied.append(dst) }
            } catch {
                if progress?.isCancelled == true { res.cancelled = true; break }
                res.errs.append("「\(name)」：\(error.localizedDescription)")
            }
        }
        return res
    }
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

/// 调试：主线程上某段代码超过 8ms 时打印（FB_PERF=1 时启用）
let perfDebug = ProcessInfo.processInfo.environment["FB_PERF"] != nil
@discardableResult @inline(__always) func perfMark<T>(_ label: @autoclosure () -> String, _ f: () -> T) -> T {
    guard perfDebug else { return f() }
    let t0 = CFAbsoluteTimeGetCurrent(); let r = f()
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    if ms > 8 { print(String(format: "PERF %6.1fms  %@", ms, label())) }
    if ms > 1 { StallWatch.marks.append(String(format: "%@=%.0f", label(), ms)) }
    return r
}

/// 调试：主线程一次 run loop 超过 30ms 时打印
enum StallWatch {
    static var t0 = CFAbsoluteTimeGetCurrent()
    static var marks: [String] = []
    static func install() {
        guard perfDebug else { return }
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, act in
            let now = CFAbsoluteTimeGetCurrent()
            if act == .afterWaiting { t0 = now; marks = [] } else { let ms = (now - t0) * 1000; if ms > 30 { print(String(format: "STALL %6.1fms ", ms) + marks.joined(separator: " ")) }; marks = [] }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }
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
