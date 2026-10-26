import SwiftUI
import AppKit
import AVFoundation

/// 自动化测试环境：--uitest <输出目录> / --snapshot <输出目录> / --compare <基准目录> <输出目录>
/// 测试在应用进程内驱动自己的界面（合成 NSEvent、走真实的响应链和菜单快捷键），
/// 不需要系统的辅助功能权限，窗口放在屏幕外且透明，不激活应用、不抢焦点。
enum TestEnv {
    static var mode: String?
    static var out = URL(fileURLWithPath: "/tmp/fb-ui-out")
    static let fixture = URL(fileURLWithPath: "/tmp/fb-ui")
    static var savedDefaults: [String: Any]?
    static var active: Bool { mode != nil }
    static let debug = ProcessInfo.processInfo.environment["FB_DEBUG"] != nil
    static func setup(_ args: [String]) {
        if let i = args.firstIndex(of: "--compare") {
            exit(compareDirs(URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2])))
        }
        for m in ["--uitest", "--snapshot"] {
            if let i = args.firstIndex(of: m) {
                mode = m
                if i + 1 < args.count { out = URL(fileURLWithPath: args[i + 1]) }
            }
        }
        guard active else { return }
        let id = Bundle.main.bundleIdentifier ?? "com.yost.filebutler"
        // 上一次测试如果被强制结束，先用备份还原用户设置
        let bk = URL(fileURLWithPath: "/tmp/fb-ui-defaults-backup.plist")
        if let data = try? Data(contentsOf: bk), let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            UserDefaults.standard.setPersistentDomain(d, forName: id)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        savedDefaults = UserDefaults.standard.persistentDomain(forName: id)
        // 备份到文件：即使测试进程被强制结束，test.sh 也能把用户的设置还原
        if let d = savedDefaults, let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/fb-ui-defaults-backup.plist"))
        }
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        makeFixture()
        let ud = UserDefaults.standard
        ud.set([fixture.path], forKey: "pane0Tabs"); ud.set(["list"], forKey: "pane0Modes"); ud.set(0, forKey: "pane0Cur")
        ud.set([fixture.appendingPathComponent("文件夹A").path], forKey: "pane1Tabs"); ud.set(["list"], forKey: "pane1Modes"); ud.set(0, forKey: "pane1Cur")
        ud.set(false, forKey: "showInfo"); ud.set(true, forKey: "showPathBar"); ud.set(80.0, forKey: "iconSize")
        ud.set(true, forKey: "fdaPromptDismissed")
        // 列宽等界面记忆用默认值，保证截图稳定（测试结束会还原）
        for k in ud.dictionaryRepresentation().keys where k.hasPrefix("NSTableView") || k.hasPrefix("NSSplitView") || k.hasPrefix("NSWindow Frame") { ud.removeObject(forKey: k) }
    }
    static func restoreDefaults() {
        let id = Bundle.main.bundleIdentifier ?? "com.yost.filebutler"
        if let d = savedDefaults { UserDefaults.standard.setPersistentDomain(d, forName: id) } else { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.synchronize()
        try? FileManager.default.removeItem(atPath: "/tmp/fb-ui-defaults-backup.plist")
    }
    static func makeFixture() {
        let fm = FileManager.default
        try? fm.removeItem(at: fixture)
        let fixed = Date(timeIntervalSince1970: 1767225600) // 2026-01-01
        func dir(_ p: String) { try? fm.createDirectory(at: fixture.appendingPathComponent(p), withIntermediateDirectories: true) }
        func file(_ p: String, _ s: String) { try? s.write(to: fixture.appendingPathComponent(p), atomically: true, encoding: .utf8) }
        dir("文件夹A"); dir("空文件夹B"); dir("文件夹C/子文件夹")
        file("文件夹A/甲.txt", "甲"); file("文件夹A/乙.txt", "乙乙")
        file("说明.txt", String(repeating: "说明", count: 50)); file("数据.csv", "a,b\n1,2\n")
        var deep = "很长的路径"
        dir(deep)
        for i in 1...12 { deep += "/第\(i)层 名字非常非常长的文件夹 Level \(i)"; dir(deep) }
        file(deep + "/最深处的文件.txt", "deep")
        makeTestVideo(fixture.appendingPathComponent("视频.mp4"))
        // 固定修改时间，让截图稳定
        if let e = fm.enumerator(at: fixture, includingPropertiesForKeys: nil) {
            for case let u as URL in e { try? fm.setAttributes([.modificationDate: fixed, .creationDate: fixed], ofItemAtPath: u.path) }
        }
        try? fm.setAttributes([.modificationDate: fixed], ofItemAtPath: fixture.path)
    }
}

/// 用 AVFoundation 生成一段 1 秒、320×180 的测试视频（渐变色块，无声）
func makeTestVideo(_ u: URL) {
    try? FileManager.default.removeItem(at: u)
    guard let w = try? AVAssetWriter(outputURL: u, fileType: .mp4) else { return }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
    w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &pb)
        guard let b = pb else { continue }
        CVPixelBufferLockBaseAddress(b, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 20 + i * 8, y: 60, width: 60, height: 60))
        CVPixelBufferUnlockBaseAddress(b, [])
        ad.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    sem.wait()
}

// MARK: 图片对比（基准图 vs 本次截图）
func loadRep(_ u: URL) -> NSBitmapImageRep? { (try? Data(contentsOf: u)).flatMap { NSBitmapImageRep(data: $0) } }
func diffRatio(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
    var bad = 0
    let step = 1
    for y in stride(from: 0, to: a.pixelsHigh, by: step) {
        for x in stride(from: 0, to: a.pixelsWide, by: step) {
            guard let c1 = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let c2 = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { bad += 1; continue }
            let d = max(abs(c1.redComponent - c2.redComponent), abs(c1.greenComponent - c2.greenComponent), abs(c1.blueComponent - c2.blueComponent))
            if d > 0.08 { bad += 1 }
        }
    }
    return Double(bad) / Double(a.pixelsWide * a.pixelsHigh)
}
func compareDirs(_ golden: URL, _ out: URL) -> Int32 {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: golden.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    if files.isEmpty { print("FAIL  没有基准图：\(golden.path)"); return 1 }
    var fails = 0
    for f in files {
        guard let g = loadRep(golden.appendingPathComponent(f)) else { print("FAIL  \(f) 基准图无法读取"); fails += 1; continue }
        guard let o = loadRep(out.appendingPathComponent(f)) else { print("FAIL  \(f) 本次没有生成"); fails += 1; continue }
        let r = diffRatio(g, o)
        let ok = r <= 0.005
        print(String(format: "%@  %@ 差异 %.3f%%", ok ? "PASS" : "FAIL", f, r * 100))
        if !ok { fails += 1 }
    }
    print("对比结果：\(files.count - fails) 通过，\(fails) 失败")
    return fails == 0 ? 0 : 1
}

// MARK: 测试运行器
@MainActor
final class UITestRunner {
    let app: AppState
    var win: NSWindow!
    var results: [(name: String, ok: Bool, detail: String, ms: Int)] = []
    var savedPB: [NSPasteboardItem] = []
    static var started = false
    init(app: AppState) { self.app = app }

    static func start(app: AppState) {
        guard TestEnv.active, !started else { return }
        started = true
        MenuCapture.install()
        let r = UITestRunner(app: app)
        Task { @MainActor in await r.run() }
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    func check(_ name: String, _ ok: Bool, _ detail: String = "", t0: Date = Date()) {
        results.append((name, ok, detail, Int(Date().timeIntervalSince(t0) * 1000)))
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
    func shot(_ name: String, view: NSView? = nil, crop: NSRect? = nil) {
        win.displayIfNeeded()
        let v = view ?? win.contentView!.superview ?? win.contentView!
        let r = crop ?? v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return }
        v.cacheDisplay(in: r, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: TestEnv.out.appendingPathComponent(name + ".png"))
    }
    func savePasteboard() {
        savedPB = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let n = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
            return n
        }
    }
    func restorePasteboard() { NSPasteboard.general.clearContents(); if !savedPB.isEmpty { NSPasteboard.general.writeObjects(savedPB) } }

    // MARK: 事件合成
    func mouse(_ t: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
        TestWindow.mouse = p
        if ProcessInfo.processInfo.environment["FB_DEBUG"] != nil, t == .rightMouseDown || t == .leftMouseDown, let fv = win.contentView?.superview {
            print("DEBUG \(t == .rightMouseDown ? "R" : "L") at \(p) hit", String(describing: fv.hitTest(fv.convert(p, from: nil)).map { Swift.type(of: $0) }))
        }
        return NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func click(_ p: NSPoint) { NSApp.postEvent(mouse(.leftMouseDown, p), atStart: false); NSApp.postEvent(mouse(.leftMouseUp, p), atStart: false) }
    /// 右键并读取弹出的菜单（菜单一开始跟踪就立即读取并关闭，不在屏幕上停留）
    var pendingMenuAction: String?
    /// 右键并读取将要弹出的菜单。测试模式下拦截了 NSMenu 的弹出方法：菜单照常构建（走真实的右键流程），但不显示在屏幕上。
    func rightClickMenu(_ p: NSPoint, choose: String? = nil) async -> [String] {
        MenuCapture.last = nil
        NSApp.postEvent(mouse(.rightMouseDown, p), atStart: false)
        NSApp.postEvent(mouse(.rightMouseUp, p), atStart: false)
        for _ in 0..<15 { if MenuCapture.last != nil { break }; await sleep(0.1) }
        guard let m = MenuCapture.last else { return [] }
        m.update()
        let titles = m.items.map { $0.isSeparatorItem ? "—" : $0.title }
        if let c = choose, let i = m.items.firstIndex(where: { $0.title == c }) { m.performActionForItem(at: i) }
        return titles
    }
    func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code)!
    }
    /// 和 NSApplication 派发键盘事件的顺序一样：先窗口里的快捷键，再主菜单，最后交给第一响应者
    func press(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        let e = key(chars, code, flags)
        if flags.contains(.command) || flags.contains(.control) {
            if win.performKeyEquivalent(with: e) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
        }
        win.sendEvent(e)
        win.sendEvent(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
    }
    func type(_ s: String) {
        if let tv = win.firstResponder as? NSTextView {
            // 输入法不在后台进程里工作，中文直接走 insertText（和输入法提交文字是同一个入口）
            tv.insertText(s, replacementRange: tv.selectedRange())
        } else { for c in s { press(String(c), 0) } }
    }
    /// 在窗口的视图树里找到这一栏当前显示的内容视图（KeyCatcher 放在每种显示方式的背景里，和内容区域一样大）
    func paneRect(_ i: Int) -> NSRect {
        var best: NSRect = .zero
        func walk(_ v: NSView) {
            if let k = v as? FBKeyView, k.pane == i, k.window === win, !k.isHiddenOrHasHiddenAncestor {
                let r = k.convert(k.bounds, to: nil)
                if r.width * r.height > best.width * best.height { best = r }
            }
            if let t = v as? NSTableView, i == 0 || true, let sv = t.enclosingScrollView, t.window === win, let d = t.delegate as? FileTable.Coordinator, d.pane == i {
                let r = sv.convert(sv.bounds, to: nil)
                if r.width * r.height > best.width * best.height { best = r }
            }
            v.subviews.forEach(walk)
        }
        if let root = win.contentView?.superview { walk(root) }
        return best
    }
    func onDisk(_ p: String) -> Bool { FileManager.default.fileExists(atPath: TestEnv.fixture.appendingPathComponent(p).path) }
    var t: TabModel { app.panes[0].tab }
    func pathText(_ i: Int = 0) -> String {
        // 读取路径栏的可访问性值（就是界面上显示的文字）
        func find(_ v: NSView) -> String? { nil }
        let w = paneRect(i).width - 40
        return pathBarLayout(pathURLs(app.panes[i].tab.pathTarget), width: w).map { $0.label }.joined(separator: " › ")
    }
    func settle(_ s: Double = 0.6) async { await sleep(s); win.displayIfNeeded() }

    // MARK: 运行
    func run() async {
        await sleep(1.2)
        guard let w = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 600 }) else { print("FAIL  找不到主窗口"); finish(); return }
        win = w
        TestWindow.win = w
        NSApp.appearance = NSAppearance(named: .aqua)
        win.appearance = NSAppearance(named: .aqua)
        win.alphaValue = 0
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1280, height: 780), display: true)
        win.makeKey()
        await settle(1.0)
        savePasteboard()
        if ProcessInfo.processInfo.environment["FB_DEBUG"] != nil {
            print("DEBUG key=\(win.isKeyWindow) main=\(win.isMainWindow) active=\(NSApp.isActive) pane0=\(paneRect(0)) win=\(win.frame)")
            var n: UInt32 = 0
            if let ms = class_copyMethodList(object_getClass(NSMenu.self), &n) { for i in 0..<Int(n) { let s = NSStringFromSelector(method_getName(ms[i])); if s.lowercased().contains("popup") || s.lowercased().contains("context") { print("DEBUG cls", s) } } }
            if let ms = class_copyMethodList(NSMenu.self, &n) { for i in 0..<Int(n) { let s = NSStringFromSelector(method_getName(ms[i])); if s.lowercased().contains("popup") { print("DEBUG inst", s) } } }
            let r = paneRect(0); let p = NSPoint(x: r.maxX - 40, y: r.minY + 20)
            print("DEBUG hit", String(describing: win.contentView?.superview?.hitTest(win.contentView!.superview!.convert(p, from: nil)).map { Swift.type(of: $0) }))
        }
        await snapshots()
        if TestEnv.mode == "--uitest" { await uiTests() }
        finish()
    }

    func snapshots() async {
        // 路径栏：不同路径、不同宽度
        let home = FileManager.default.homeDirectoryForCurrentUser
        var deep = TestEnv.fixture.appendingPathComponent("很长的路径")
        for i in 1...12 { deep.appendPathComponent("第\(i)层 名字非常非常长的文件夹 Level \(i)") }
        let cases: [(String, URL)] = [("root", URL(fileURLWithPath: "/")), ("downloads", home.appendingPathComponent("Downloads")),
                                      ("appsupport", home.appendingPathComponent("Library/Application Support")), ("verylong", deep)]
        for (n, u) in cases {
            for width in [300, 500, 900] {
                let tab = TabModel(path: u, app: app, mode: .list)
                let host = NSHostingView(rootView: PathBar(tab: tab, index: 0).environmentObject(app).frame(width: CGFloat(width), height: 28))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 28)
                let pw = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                pw.appearance = NSAppearance(named: .aqua); pw.contentView = host
                host.layoutSubtreeIfNeeded(); await sleep(0.15); host.layoutSubtreeIfNeeded(); host.display()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: TestEnv.out.appendingPathComponent("pb-\(n)-\(width).png"))
                }
                let segs = pathBarLayout(pathURLs(u), width: CGFloat(width) - 16 - 24)
                let labels = segs.map { $0.label }
                let noEmpty = labels.allSatisfy { !$0.isEmpty && $0 != "…" || segs.first(where: { $0.label == "…" })?.hidden.isEmpty == false }
                let firstOK = labels.first.map { $0 == rootVolumeName || ($0.contains("…") && width <= 300) } ?? false
                let lastOK = n == "verylong" ? (labels.last?.hasSuffix("12") ?? false) : labels.last == pathLabel(u)
                let count = pathURLs(u).count
                check("路径栏 \(n) @\(width)pt", noEmpty && firstOK && lastOK && segs.count <= count, labels.joined(separator: " › "))
            }
        }
        check("路径栏「/」只有一段", pathURLs(URL(fileURLWithPath: "/")).count == 1)
        check("路径栏「下载」4 段且名称本地化", pathBarLayout(pathURLs(home.appendingPathComponent("Downloads")), width: 900).map { $0.label } == [rootVolumeName, pathLabel(URL(fileURLWithPath: "/Users")), pathLabel(home), pathLabel(home.appendingPathComponent("Downloads"))],
              pathBarLayout(pathURLs(home.appendingPathComponent("Downloads")), width: 900).map { $0.label }.joined(separator: " › "))
        // 整个窗口：四种显示方式
        app.active = 0
        for (i, m) in ViewMode.allCases.enumerated() {
            app.setViewMode(m); await settle(1.0)
            shot("window-\(i + 1)-\(m.rawValue)")
            let r = paneRect(0)
            if m == .list || m == .column { shot("pane-\(m.rawValue)", crop: win.contentView!.superview!.convert(r, from: nil)) }
        }
        app.setViewMode(.list); await settle()
        shot("toolbar", crop: NSRect(x: 0, y: win.contentView!.superview!.bounds.height - 60, width: win.contentView!.superview!.bounds.width, height: 60))
    }

    func uiTests() async {
        let F = TestEnv.fixture.realFileURL
        app.active = 0
        let bgWant = ["新建文件夹", "粘贴项目", "—", "显示简介", "—", "显示", "使用群组", "排序方式", "查看显示选项", "—", "文件管家"]
        func bgOK(_ t: [String]) -> Bool { t.map { $0.hasPrefix("粘贴") ? "粘贴项目" : $0 } == bgWant }

        // 1. ⌘1–⌘4 切换显示方式（走主菜单快捷键）
        for (i, m) in ViewMode.allCases.enumerated() {
            press("\(i + 1)", [18, 19, 20, 21][i], .command); await settle()
            check("⌘\(i + 1) 切换到\(m.title)", t.viewMode == m, t.viewMode.title)
        }
        // 2. 每种显示方式的空白处右键都有背景菜单
        for (i, m) in ViewMode.allCases.enumerated() {
            press("\(i + 1)", [18, 19, 20, 21][i], .command); await settle(0.8)
            let r = paneRect(0)
            // 画廊底部是缩略图条，空白处取上方大图区域的角落
            let p = m == .gallery ? NSPoint(x: r.minX + 8, y: r.maxY - 8) : NSPoint(x: r.maxX - 40, y: r.minY + 20)
            let titles = await rightClickMenu(p)
            check("\(m.title)视图空白处右键 → 背景菜单", bgOK(titles), titles.joined(separator: " | "))
        }
        app.dual = false; await settle(0.6)
        // 3. 分栏：点文件夹 → 路径栏跟随；空文件夹 / 栏下方空白 / 最右侧空白都有菜单
        press("3", 20, .command); await settle(0.8)
        var r = paneRect(0)
        func rowPoint(col: Int, row: Int) -> NSPoint { NSPoint(x: r.minX + CGFloat(col) * 231 + 80, y: r.maxY - 4 - CGFloat(row) * 22 - 11) }
        let items0 = t.display.map { $0.name }
        if let ia = items0.firstIndex(of: "文件夹A") {
            click(rowPoint(col: 0, row: ia)); await settle(0.8)
            check("分栏：点按「文件夹A」打开下一栏", t.columnChain.last?.lastPathComponent == "文件夹A", t.columnChain.map { $0.lastPathComponent }.joined(separator: "/"))
            let pt = pathText()
            check("分栏：路径栏显示到「文件夹A」", pt.hasSuffix("fb-ui › 文件夹A") && pt.hasPrefix(rootVolumeName), pt)
            shot("ui-column-folderA")
            let titles = await rightClickMenu(NSPoint(x: r.minX + 231 + 100, y: r.minY + 20))
            check("分栏：第 2 栏下方空白右键 → 背景菜单", bgOK(titles), titles.joined(separator: " | "))
            let titles2 = await rightClickMenu(NSPoint(x: r.minX + 231 * 2 + 120, y: r.minY + 20))
            check("分栏：最右侧空白右键 → 背景菜单", bgOK(titles2), titles2.joined(separator: " | "))
        } else { check("分栏：找到文件夹A", false, items0.joined(separator: ",")) }
        if let ib = items0.firstIndex(of: "空文件夹B") {
            click(rowPoint(col: 0, row: ib)); await settle(0.8)
            check("分栏：打开空文件夹", t.columnChain.last?.lastPathComponent == "空文件夹B")
            let p = NSPoint(x: r.minX + 231 + 100, y: r.maxY - 60)
            let titles = await rightClickMenu(p, choose: "新建文件夹")
            check("分栏：空文件夹里右键 → 背景菜单", bgOK(titles), titles.joined(separator: " | "))
            await settle(0.8)
            check("分栏：在空文件夹里新建「未命名文件夹」", onDisk("空文件夹B/未命名文件夹"))
            check("分栏：新建后进入就地重命名", app.inlineRename?.lastPathComponent == "未命名文件夹" && win.firstResponder is NSTextView, String(describing: win.firstResponder))
            shot("ui-column-newfolder-inline")
            type("分栏新建")
            if TestEnv.debug { print("DEBUG col before return sel=\(t.selection.map { $0.path }) fr=\(String(describing: win.firstResponder))") }
            press("\r", 36); await settle(0.8)
            if TestEnv.debug { print("DEBUG col after return sel=\(t.selection.map { $0.path })") }
            check("分栏：输入名字 + 回车 → 磁盘上已改名", onDisk("空文件夹B/分栏新建") && !onDisk("空文件夹B/未命名文件夹"))
            let pt = pathText()
            check("分栏：路径栏跟随新文件夹", pt.contains("空文件夹B"), pt + " sel=" + t.selection.map { $0.path }.joined(separator: ",") + " chain=" + t.columnChain.map { $0.lastPathComponent }.joined(separator: "/"))
        }
        // 4. 列表：⇧⌘N + 就地重命名
        press("2", 19, .command); await settle(0.8)
        t.selection = []
        if TestEnv.debug { print("DEBUG before ⇧⌘N mode=\(t.viewMode) fr=\(String(describing: win.firstResponder))") }
        press("N", 45, [.command, .shift])
        for k in 0..<8 { await sleep(0.1); if ProcessInfo.processInfo.environment["FB_DEBUG"] != nil { print("DEBUG fr[\(k)] \(String(describing: win.firstResponder)) inline=\(String(describing: app.inlineRename?.lastPathComponent))") } }
        check("⇧⌘N 新建「未命名文件夹」", onDisk("未命名文件夹"))
        check("⇧⌘N 后直接进入就地重命名（全选名字）", win.firstResponder is NSTextView && (win.firstResponder as? NSTextView)?.selectedRange().length == "未命名文件夹".count, String(describing: (win.firstResponder as? NSTextView)?.selectedRange()))
        shot("ui-list-newfolder-inline")
        type("列表新建"); press("\r", 36); await settle(0.8)
        check("回车确认 → 磁盘上为「列表新建」", onDisk("列表新建") && !onDisk("未命名文件夹"))
        // 回车重命名文件：只选中不含扩展名的部分
        t.selection = [F.appendingPathComponent("数据.csv")]; app.focusActiveTable(); await settle(0.5)
        press("\r", 36); await settle(0.6)
        let sel = (win.firstResponder as? NSTextView)?.selectedRange()
        check("回车重命名文件：选中不含扩展名", sel?.length == 2, String(describing: sel))
        press("\u{1b}", 53); await settle(0.5)
        check("Esc 取消重命名", onDisk("数据.csv"))
        // 5. ⌘C / ⌘V / ⌘⌫ / ⌘Z
        t.selection = [F.appendingPathComponent("说明.txt")]; app.focusActiveTable(); await settle(0.4)
        press("c", 8, .command); press("v", 9, .command); await settle(1.0)
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: F.path)) ?? []).filter { $0.hasPrefix("说明") }
        check("⌘C ⌘V 生成副本", copies.count == 2, copies.joined(separator: ", "))
        if let c = copies.first(where: { $0 != "说明.txt" }) {
            t.selection = [F.appendingPathComponent(c)]; app.focusActiveTable(); await settle(0.4)
            press("\u{8}", 51, .command); await settle(1.0)
            check("⌘⌫ 移到废纸篓", !onDisk(c))
            press("z", 6, .command); await settle(1.0)
            check("⌘Z 撤销 → 文件回来了", onDisk(c))
            t.selection = [F.appendingPathComponent(c)]; press("\u{8}", 51, .command); await settle(0.8)
            app.undoStack.removeAll()
        }
        // 6. 右键未选中的项目会先选中它（列表）
        t.clearSearch(); await settle(0.5)
        let rows = t.display.map { $0.url }
        if let i = rows.firstIndex(where: { $0.lastPathComponent == "文件夹A" }) {
            t.selection = []; await settle(0.4)
            r = paneRect(0)
            let titles = await rightClickMenu(NSPoint(x: r.minX + 60, y: r.maxY - 24 - CGFloat(i) * 24 - 12))
            await settle(0.4)
            check("列表：右键项目 → 项目菜单（打开 在前）", titles.first == "打开", titles.prefix(6).joined(separator: " | "))
            check("列表：右键会先选中该项目", t.selection.map { $0.lastPathComponent } == ["文件夹A"], t.selection.map { $0.lastPathComponent }.joined())
        }
        // 6b. 图标/分栏视图：右键未选中的项目会先选中它
        for (key, code, name) in [("1", UInt16(18), "图标"), ("3", UInt16(20), "分栏")] {
            press(key, code, .command); await settle(1.0)
            t.selection = []; t.columnChain = []; await settle(0.4)
            // 等到第一个项目的位置标记已经放进窗口并且有尺寸（条件等待，最多 4 秒）
            let firstURL = t.display.first?.url
            for _ in 0..<40 {
                if RightClick.markers.allObjects.contains(where: { $0.window === win && samePath($0.url, firstURL) && $0.bounds.width > 0 }) { break }
                await sleep(0.1)
            }
            let rr = paneRect(0)
            let p = name == "图标" ? NSPoint(x: rr.minX + 12 + 58, y: rr.maxY - 12 - 50) : NSPoint(x: rr.minX + 80, y: rr.maxY - 4 - 11)
            let titles = await rightClickMenu(p)
            await settle(0.3)
            let first = t.display.first?.name ?? ""
            check("\(name)：右键项目 → 先选中它并弹出项目菜单", titles.first == "打开" && t.selection.map { $0.lastPathComponent } == [first], "\(t.selection.map { $0.lastPathComponent }) \(titles.prefix(3))")
            if name == "图标" { shot("ui-icon-rightclick-selected") }
        }
        press("2", 19, .command); await settle(0.6)
        // 6c. 列表视图的列：名称、修改日期、大小、种类都可见（双栏和单栏、不同窗口宽度）
        func visibleCols(_ pane: Int) -> [String: CGFloat] {
            var out: [String: CGFloat] = [:]
            func walk(_ v: NSView) {
                if let tv = v as? NSTableView, tv.window === win, let d = tv.delegate as? FileTable.Coordinator, d.pane == pane, let clip = tv.enclosingScrollView?.contentView {
                    if TestEnv.debug { print("DEBUG cols pane=\(pane) clip=\(clip.bounds.width) tv=\(tv.frame.width) " + tv.tableColumns.enumerated().map { "\($0.element.identifier.rawValue):\($0.element.isHidden ? "h" : "")\(Int($0.element.width))@\(Int(tv.rect(ofColumn: $0.offset).maxX))" }.joined(separator: " ")) }
                    for (i, c) in tv.tableColumns.enumerated() where !c.isHidden && c.width > 0 {
                        let r = tv.convert(tv.rect(ofColumn: i), to: clip)
                        if r.maxX <= clip.bounds.maxX + 1 { out[c.identifier.rawValue] = c.width }
                    }
                }
                v.subviews.forEach(walk)
            }
            walk(win.contentView!.superview!)
            return out
        }
        app.dual = true; app.active = 1; press("2", 19, .command); app.active = 0; press("2", 19, .command); await settle(0.8)
        if TestEnv.debug { print("DEBUG modes \(app.panes[0].tab.viewMode) \(app.panes[1].tab.viewMode)") }
        for w in [1280.0, 900.0] {
            win.setFrame(NSRect(x: -6000, y: -6000, width: w, height: 780), display: true); await settle(0.8)
            for pn in [0, 1] {
                let cols = visibleCols(pn)
                let pw = paneRect(pn).width
                // 期望：按这一栏的宽度，规划出来的列都要完整可见；栏宽够 320 时至少有名称和修改日期
                let want = FileTable.Coordinator.plan(avail: pw, enabled: ["date", "size", "kind"], search: false).map { $0.0 }
                let ok = want.allSatisfy { cols[$0] != nil } && (pw < 320 || (cols["name"] != nil && cols["date"] != nil)) && (pw < 560 || cols.count == 4)
                check("列表（双栏，窗口 \(Int(w))，\(pn == 0 ? "左" : "右")栏宽 \(Int(pw))）：列完整可见、没有被挤出可视区", ok, cols.map { "\($0.key)=\(Int($0.value))" }.sorted().joined(separator: " "))
            }
        }
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1280, height: 780), display: true); await settle(0.8)
        shot("list-view-window")
        let rp = paneRect(1)
        shot("list-view", crop: win.contentView!.superview!.convert(rp, from: nil))
        app.dual = false; await settle(0.8)
        let single = visibleCols(0)
        check("列表（单栏）：名称/修改日期/大小/种类列可见", ["name", "date", "size", "kind"].allSatisfy { single[$0] != nil }, single.map { "\($0.key)=\(Int($0.value))" }.sorted().joined(separator: " "))
        check("列宽规划：很窄时依次隐藏 种类 → 大小", FileTable.Coordinator.plan(avail: 330, enabled: ["date", "size", "kind"], search: false).map { $0.0 } == ["name", "date"])
        // 7. ⌘F 搜索
        press("f", 3, .command); await settle(0.6)
        if TestEnv.debug {
            func walk(_ v: NSView, _ d: Int) { if let t = v as? NSTextField { print("DEBUG tf \(Swift.type(of: t)) ph=\(String(describing: t.placeholderString)) pha=\(String(describing: t.placeholderAttributedString?.string)) ed=\(t.isEditable)") }; v.subviews.forEach { walk($0, d + 1) } }
            walk(win.contentView!.superview!, 0)
            for it in win.toolbar?.items ?? [] { if let v = it.view { walk(v, 0) } }
        }
        let inSearch = (win.firstResponder as? NSTextView).map { ($0.delegate as? NSTextField)?.placeholderString == "搜索" } ?? false
        check("⌘F 聚焦搜索框", inSearch, String(describing: win.firstResponder))
        type("说明"); await settle(1.0)
        check("搜索「说明」只显示匹配项", t.searchText == "说明" && t.display.map { $0.name } == ["说明.txt"], t.display.map { $0.name }.joined(separator: ","))
        shot("ui-search")
        press("\u{1b}", 53); await settle(0.6)
        t.clearSearch(); await settle(0.4)
        // 8. ⇧⌘P 预览
        let before = app.showPreview
        press("P", 35, [.command, .shift]); await settle(0.6)
        check("⇧⌘P 显示预览栏", app.showPreview != before)
        shot("ui-preview")
        press("P", 35, [.command, .shift]); await settle(0.4)
        // 9. ⌥⌘P 路径栏开关
        press("p", 35, [.command, .option]); await settle(0.4)
        let hidden = !app.showPathBar
        press("p", 35, [.command, .option]); await settle(0.4)
        check("⌥⌘P 显示/隐藏路径栏", hidden && app.showPathBar)
        // 9b. 视频预览：默认不播放，点按播放按钮才播放；换选中项就停止
        press("2", 19, .command); await settle(0.5)
        t.clearSearch(); app.showPreview = true
        let created0 = MediaPreviewState.created
        t.selection = [F.appendingPathComponent("视频.mp4")]; app.focusActiveTable(); await settle(2.0)
        check("视频预览：选中后不自动播放（没有创建播放器）", MediaPreviewState.created == created0 && MediaPreviewState.player == nil, "created=\(MediaPreviewState.created - created0)")
        check("视频预览：显示播放按钮", PlayButtonRegistry.marker?.window === win)
        let pr = paneRect(app.dual ? 1 : 0)
        let full = win.contentView!.superview!
        let crop = NSRect(x: pr.maxX + 1, y: 30, width: full.bounds.width - pr.maxX - 1, height: full.bounds.height - 70)
        shot("video-preview", crop: crop)
        if let mk = PlayButtonRegistry.marker {
            let c = mk.convert(NSPoint(x: mk.bounds.midX, y: mk.bounds.midY), to: nil)
            click(c); await settle(1.0)
            check("视频预览：点按播放按钮后开始播放", MediaPreviewState.created == created0 + 1 && (MediaPreviewState.player?.rate ?? 0) > 0, "rate=\(MediaPreviewState.player?.rate ?? -1)")
            shot("ui-video-playing")
        }
        let playing = MediaPreviewState.player
        t.selection = [F.appendingPathComponent("说明.txt")]; await settle(1.0)
        check("视频预览：换选中项后停止并释放播放器", (playing?.rate ?? 0) == 0 && playing?.currentItem == nil, "rate=\(playing?.rate ?? -1)")
        app.showPreview = false; await settle(0.4)
        // 10. 右栏的路径栏是右栏自己的路径
        app.dual = true; await settle(0.6)
        let p1 = pathText(1)
        check("右栏路径栏反映右栏（文件夹A）", p1.hasSuffix("文件夹A"), p1)
        shot("ui-final")
    }

    func finish() {
        restorePasteboard()
        TestEnv.restoreDefaults()
        let fails = results.filter { !$0.ok }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"FileButler\(TestEnv.mode ?? "")\" tests=\"\(results.count)\" failures=\"\(fails.count)\">\n"
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        for r in results {
            xml += "  <testcase name=\"\(esc(r.name))\">" + (r.ok ? "" : "<failure message=\"\(esc(r.detail))\"/>") + "<system-out>\(esc(r.detail))</system-out></testcase>\n"
        }
        xml += "</testsuite>\n"
        try? xml.write(to: TestEnv.out.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        print("界面测试：\(results.count - fails.count) 通过，\(fails.count) 失败；截图和报告在 \(TestEnv.out.path)")
        fflush(stdout)
        exit(fails.isEmpty && !results.isEmpty ? 0 : 1)
    }
}

/// 测试模式：拦截上下文菜单的弹出（只记录，不显示）
enum TestWindow { static weak var win: NSWindow?; static var mouse = NSPoint.zero }
enum MenuCapture {
    static var last: NSMenu?
    static var via = ""
    static func install() {
        let cls: AnyClass = object_getClass(NSMenu.self)!
        let pairs: [(Selector, Selector)] = [
            (#selector(NSMenu.popUpContextMenu(_:with:for:)), #selector(NSMenu.fbt_popUpContextMenu(_:with:for:))),
            (#selector(NSMenu.popUpContextMenu(_:with:for:with:)), #selector(NSMenu.fbt_popUpContextMenu(_:with:for:with:))),
        ]
        for (o, n) in pairs { if let m1 = class_getClassMethod(NSMenu.self, o), let m2 = class_getClassMethod(NSMenu.self, n) { method_exchangeImplementations(m1, m2) } }
        _ = cls
        // AppKit 内部最终都会走这几个私有入口；替换成「只记录不显示」
        typealias Blk = @convention(block) (NSMenu, AnyObject?, NSView?, NSFont?, AnyObject?) -> Void
        typealias Blk4 = @convention(block) (NSMenu, AnyObject?, NSView?, NSFont?) -> Void
        typealias Blk3 = @convention(block) (NSMenu, AnyObject?, NSView?) -> Void
        let b5: Blk = { m, _, _, _, _ in NSMenu.capture(m, "private5") }
        let b4: Blk4 = { m, _, _, _ in NSMenu.capture(m, "private4") }
        let b3: Blk3 = { m, _, _ in NSMenu.capture(m, "private3") }
        for sel in ["_popUpContextMenu:withContext:forView:withFont:completionBlock:", "_popUpContextMenu:withEvent:forView:withFont:completionBlock:"] {
            if let m = class_getInstanceMethod(NSMenu.self, NSSelectorFromString(sel)) { method_setImplementation(m, imp_implementationWithBlock(b5)) }
        }
        for sel in ["_popUpContextMenu:withContext:forView:withFont:", "_popUpContextMenu:withEvent:forView:withFont:"] {
            if let m = class_getInstanceMethod(NSMenu.self, NSSelectorFromString(sel)) { method_setImplementation(m, imp_implementationWithBlock(b4)) }
        }
        for sel in ["_popUpContextMenu:withContext:forView:", "_popUpContextMenu:withEvent:forView:"] {
            if let m = class_getInstanceMethod(NSMenu.self, NSSelectorFromString(sel)) { method_setImplementation(m, imp_implementationWithBlock(b3)) }
        }
        // 测试窗口在后台（不激活应用、不抢焦点），但要让它表现得像前台的主窗口：
        // 鼠标第一次点按就生效、可以成为第一响应者、文本框能编辑
        typealias BoolBlk = @convention(block) (NSObject) -> Bool
        let keyBlk: BoolBlk = { w in (w as? NSWindow) === TestWindow.win }
        for sel in ["isKeyWindow", "isMainWindow", "_isKeyWindowIgnoringFocus"] {
            if let m = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(sel)) {
                let orig = method_getImplementation(m)
                typealias F = @convention(c) (NSObject, Selector) -> Bool
                let o = unsafeBitCast(orig, to: F.self); let sl = NSSelectorFromString(sel)
                let b: BoolBlk = { w in keyBlk(w) || o(w, sl) }
                method_setImplementation(m, imp_implementationWithBlock(b))
            }
        }
        typealias Cls4 = @convention(block) (AnyObject, NSMenu, AnyObject?, NSView?, AnyObject?) -> Void
        let c4: Cls4 = { _, m, _, _, _ in NSMenu.capture(m, "cls-private") }
        for sel in ["_popUpContextMenu:withEvent:forView:completionBlock:", "_popUpContextMenu:withContext:forView:completionBlock:"] {
            if let m = class_getClassMethod(NSMenu.self, NSSelectorFromString(sel)) { method_setImplementation(m, imp_implementationWithBlock(c4)) }
        }
        // 合成的鼠标事件：让「当前鼠标位置」也指向事件位置（SwiftUI 手势会读取它）
        typealias PtBlk = @convention(block) (AnyObject) -> NSPoint
        let wp: PtBlk = { _ in TestWindow.mouse }
        if let m = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.mouseLocationOutsideOfEventStream)) { method_setImplementation(m, imp_implementationWithBlock(wp)) }
        let sp: PtBlk = { _ in TestWindow.win.map { $0.convertPoint(toScreen: TestWindow.mouse) } ?? .zero }
        if let m = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.mouseLocation)) { method_setImplementation(m, imp_implementationWithBlock(sp)) }
        if let m = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("isActive")) {
            let b: BoolBlk = { _ in true }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
        if let m1 = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.popUp(positioning:at:in:))), let m2 = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.fbt_popUp(positioning:at:in:))) { method_exchangeImplementations(m1, m2) }
    }
}
extension NSMenu {
    @objc class func fbt_popUpContextMenu(_ menu: NSMenu, with e: NSEvent, for v: NSView) { capture(menu, "popUpContextMenu") }
    @objc class func fbt_popUpContextMenu(_ menu: NSMenu, with e: NSEvent, for v: NSView, with f: NSFont?) { capture(menu, "popUpContextMenu+font") }
    @objc func fbt_popUp(positioning item: NSMenuItem?, at p: NSPoint, in v: NSView?) -> Bool { NSMenu.capture(self, "popUp"); return false }
    static func capture(_ m: NSMenu, _ via: String) {
        if ProcessInfo.processInfo.environment["FB_DEBUG"] != nil { print("DEBUG captured via \(via) items=\(m.items.count)") }
        m.delegate?.menuNeedsUpdate?(m)
        MenuCapture.last = m; MenuCapture.via = via
    }
}
