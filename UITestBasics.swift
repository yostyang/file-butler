import SwiftUI
import AppKit
import Foundation

/// 测试用的拖放信息：走和真实拖放完全相同的 validateDrop / acceptDrop 代码
final class FakeDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard; let mask: NSDragOperation
    init(_ urls: [URL], mask: NSDragOperation = [.copy, .move, .link, .generic]) {
        pb = NSPasteboard(name: NSPasteboard.Name("fb-test-drag")); pb.clearContents(); pb.writeObjects(urls.map { $0 as NSURL })
        self.mask = mask
    }
    var draggingDestinationWindow: NSWindow? { TestWindow.win }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension UITestRunner {
    var fm: FileManager { FileManager.default }
    func tableCoord(_ pane: Int) -> (NSTableView, FileTable.Coordinator)? {
        var out: (NSTableView, FileTable.Coordinator)?
        func walk(_ v: NSView) { if out != nil { return }; if let t = v as? NSTableView, t.window === win, !t.isHiddenOrHasHiddenAncestor, let c = t.delegate as? FileTable.Coordinator, c.pane == pane { out = (t, c) }; v.subviews.forEach(walk) }
        walk(win.contentView!.superview!); return out
    }
    func iconCoord(_ pane: Int) -> (FBCollectionView, IconCollection.Coordinator)? {
        var out: (FBCollectionView, IconCollection.Coordinator)?
        func walk(_ v: NSView) { if out != nil { return }; if let t = v as? FBCollectionView, t.window === win, !t.isHiddenOrHasHiddenAncestor, let c = t.coord, c.pane == pane { out = (t, c) }; v.subviews.forEach(walk) }
        walk(win.contentView!.superview!); return out
    }
    func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    /// 条件等待（每 20ms 检查一次），返回耗时毫秒
    @discardableResult func waitUntil(_ timeout: Double = 10, _ cond: () -> Bool) async -> Int {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < timeout { await sleep(0.02) }
        return Int(Date().timeIntervalSince(t0) * 1000)
    }
    func idle() -> Bool { app.busyText == nil && app.progress == nil }
    func names(_ d: URL) -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: d.path)) ?? []) }
    func shown(_ pane: Int) -> Set<String> { Set(app.panes[pane].tab.display.map { $0.name }) }
    func moveMouse(to p: NSPoint) async {
        NSApp.postEvent(mouse(.mouseMoved, p), atStart: false); await settle(0.25)
    }
    func center(_ pane: Int) -> NSPoint { let r = paneRect(pane); return NSPoint(x: r.midX, y: r.midY) }
    func go(_ pane: Int, _ u: URL, _ mode: ViewMode) async {
        let t = app.panes[pane].tab
        t.navigate(u); if t.viewMode != mode { t.viewMode = mode }
        app.objectWillChange.send()
        await waitUntil(5) { !t.loading && t.path.realFileURL.path == u.realFileURL.path }
        await settle(0.5)
    }
    func mkfile(_ u: URL, _ s: String = "x") { try? s.write(to: u, atomically: false, encoding: .utf8) }

    // MARK: 全量基础功能回归 + 分栏拖拽 + 活动栏跟随鼠标 + 性能
    func regressionTests() async {
        let F = TestEnv.fixture.realFileURL
        let D = F.appendingPathComponent("回归"), L = D.appendingPathComponent("左"), R = D.appendingPathComponent("右")
        try? fm.removeItem(at: D)
        for d in [L, R, L.appendingPathComponent("子A"), R.appendingPathComponent("收件")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for n in ["a1.txt", "a2.txt", "a3.txt", "c1.txt"] { mkfile(L.appendingPathComponent(n), n) }
        mkfile(R.appendingPathComponent("b1.txt"), "b1")
        app.dual = true; app.showPreview = false; await settle(0.5)
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1280, height: 780), display: true)
        await go(0, L, .list); await go(1, R, .list)
        var trashed: [URL] = []

        // ===== 拖拽：列表视图 =====
        if let (tv1, c1) = tableCoord(1), let (tv0, c0) = tableCoord(0) {
            var t0 = Date()
            DragMods.override = []
            var d = FakeDrag([L.appendingPathComponent("a1.txt")])
            var op = c1.tableView(tv1, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            let ok1 = c1.tableView(tv1, acceptDrop: d, row: -1, dropOperation: .on)
            var ms = await waitUntil { exists(R.appendingPathComponent("a1.txt")) && !exists(L.appendingPathComponent("a1.txt")) && shown(1).contains("a1.txt") && !shown(0).contains("a1.txt") && idle() }
            check("拖拽（列表）：左 → 右，同一卷默认移动，两栏立即刷新", op == .move && ok1 && shown(1).contains("a1.txt") && !shown(0).contains("a1.txt"), "op=\(op.rawValue) \(ms)ms", t0: t0)
            t0 = Date(); DragMods.override = .option
            d = FakeDrag([R.appendingPathComponent("b1.txt")])
            op = c0.tableView(tv0, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            _ = c0.tableView(tv0, acceptDrop: d, row: -1, dropOperation: .on)
            ms = await waitUntil { exists(L.appendingPathComponent("b1.txt")) && shown(0).contains("b1.txt") && idle() }
            check("拖拽（列表）：右 → 左，按 ⌥ 强制拷贝", op == .copy && exists(R.appendingPathComponent("b1.txt")) && shown(0).contains("b1.txt"), "op=\(op.rawValue) \(ms)ms", t0: t0)
            t0 = Date(); DragMods.override = []
            d = FakeDrag([L.appendingPathComponent("a2.txt"), L.appendingPathComponent("a3.txt")])
            let row = c1.rows.firstIndex { if case .item(let it) = $0 { return it.name == "收件" }; return false } ?? -1
            op = c1.tableView(tv1, validateDrop: d, proposedRow: row, proposedDropOperation: .on)
            _ = c1.tableView(tv1, acceptDrop: d, row: row, dropOperation: .on)
            ms = await waitUntil { exists(R.appendingPathComponent("收件/a2.txt")) && exists(R.appendingPathComponent("收件/a3.txt")) && idle() }
            check("拖拽（列表）：多选拖到对侧文件夹行 → 放进该文件夹", row >= 0 && op == .move && exists(R.appendingPathComponent("收件/a3.txt")) && !exists(L.appendingPathComponent("a2.txt")), "\(ms)ms", t0: t0)
            t0 = Date(); DragMods.override = .command
            op = c1.tableView(tv1, validateDrop: FakeDrag([L.appendingPathComponent("c1.txt")]), proposedRow: -1, proposedDropOperation: .on)
            check("拖拽：按 ⌘ 强制移动", op == .move, "op=\(op.rawValue)", t0: t0)
            op = c1.tableView(tv1, validateDrop: FakeDrag([L.appendingPathComponent("c1.txt")], mask: .generic), proposedRow: -1, proposedDropOperation: .on)
            check("拖拽：按 ⌘ 时系统只允许 generic 也能放下", op == .generic, "op=\(op.rawValue)")
            t0 = Date(); DragMods.override = [.option, .command]
            d = FakeDrag([R.appendingPathComponent("b1.txt")])
            op = c0.tableView(tv0, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            _ = c0.tableView(tv0, acceptDrop: d, row: -1, dropOperation: .on)
            ms = await waitUntil { exists(L.appendingPathComponent("b1 2.txt")) }
            let alias = try? URL(resolvingAliasFileAt: L.appendingPathComponent("b1 2.txt"))
            check("拖拽：⌥⌘ 在对侧制作替身", op == .link && alias?.lastPathComponent == "b1.txt", "op=\(op.rawValue)", t0: t0)
            DragMods.override = []
            op = c0.tableView(tv0, validateDrop: FakeDrag([L.appendingPathComponent("c1.txt")]), proposedRow: -1, proposedDropOperation: .on)
            check("拖拽：拖回原文件夹不做任何事", op == [], "op=\(op.rawValue)")
            // 从访达 / 桌面拖进来
            let ext = URL(fileURLWithPath: "/tmp/fb-ui-ext").realFileURL
            try? fm.removeItem(at: ext); try? fm.createDirectory(at: ext, withIntermediateDirectories: true); mkfile(ext.appendingPathComponent("外部.txt"))
            t0 = Date(); d = FakeDrag([ext.appendingPathComponent("外部.txt")])
            op = c0.tableView(tv0, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            _ = c0.tableView(tv0, acceptDrop: d, row: -1, dropOperation: .on)
            ms = await waitUntil { shown(0).contains("外部.txt") && idle() }
            check("拖拽：从访达 / 桌面拖进来（同一卷 = 移动）", op == .move && exists(L.appendingPathComponent("外部.txt")), "\(ms)ms", t0: t0)
            try? fm.removeItem(at: ext)
            // 拖出去：拖放源写入文件 URL（访达、桌面、其他 App 都能接收）
            let r0 = c0.rows.firstIndex { if case .item(let it) = $0 { return it.name == "c1.txt" }; return false } ?? 0
            let w = c0.tableView(tv0, pasteboardWriterForRow: r0) as? NSURL
            check("拖拽：拖出到访达 / 桌面（提供文件 URL，允许拷贝和移动）", w?.isFileURL == true && w?.lastPathComponent == "c1.txt")
        } else { check("拖拽（列表）：找到两栏的表格", false) }

        // 侧边栏 / 路径栏拖放（SwiftUI onDrop → 同一个入口）
        var t0 = Date()
        _ = app.dropProviders([NSItemProvider(object: L.appendingPathComponent("c1.txt") as NSURL)], to: R)
        var ms = await waitUntil { exists(R.appendingPathComponent("c1.txt")) && idle() }
        check("拖拽：拖到侧边栏 / 路径栏的文件夹", exists(R.appendingPathComponent("c1.txt")) && !exists(L.appendingPathComponent("c1.txt")), "\(ms)ms", t0: t0)

        // ===== 拖拽：图标视图 =====
        mkfile(L.appendingPathComponent("i1.txt"))
        await go(0, L, .icon); await go(1, R, .icon)
        if let (cv1, k1) = iconCoord(1), let (cv0, k0) = iconCoord(0) {
            t0 = Date()
            var d = FakeDrag([L.appendingPathComponent("i1.txt")])
            var ip = NSIndexPath(forItem: 0, inSection: 0)
            var op: NSCollectionView.DropOperation = .before
            var r = k1.collectionView(cv1, validateDrop: d, proposedIndexPath: &ip, dropOperation: &op)
            _ = k1.collectionView(cv1, acceptDrop: d, indexPath: ip as IndexPath, dropOperation: op)
            ms = await waitUntil { shown(1).contains("i1.txt") && !shown(0).contains("i1.txt") && idle() }
            check("拖拽（图标）：左 → 右空白处 = 移进右栏当前文件夹", r == .move && exists(R.appendingPathComponent("i1.txt")), "\(ms)ms", t0: t0)
            t0 = Date()
            d = FakeDrag([L.appendingPathComponent("子A")])
            ip = (k1.index.first { $0.key.lastPathComponent == "收件" }?.value ?? IndexPath(item: 0, section: 0)) as NSIndexPath
            op = .on
            r = k1.collectionView(cv1, validateDrop: d, proposedIndexPath: &ip, dropOperation: &op)
            let hl = k1.dropURL?.lastPathComponent
            _ = k1.collectionView(cv1, acceptDrop: d, indexPath: ip as IndexPath, dropOperation: op)
            ms = await waitUntil { exists(R.appendingPathComponent("收件/子A")) && idle() }
            check("拖拽（图标）：拖到对侧文件夹图标上 → 高亮并放进该文件夹", r == .move && hl == "收件" && exists(R.appendingPathComponent("收件/子A")), "高亮=\(hl ?? "无") \(ms)ms", t0: t0)
            t0 = Date(); DragMods.override = .option
            d = FakeDrag([R.appendingPathComponent("i1.txt")]); ip = NSIndexPath(forItem: 0, inSection: 0); op = .before
            r = k0.collectionView(cv0, validateDrop: d, proposedIndexPath: &ip, dropOperation: &op)
            _ = k0.collectionView(cv0, acceptDrop: d, indexPath: ip as IndexPath, dropOperation: op)
            ms = await waitUntil { shown(0).contains("i1.txt") && idle() }
            DragMods.override = []
            check("拖拽（图标）：右 → 左，按 ⌥ 拷贝", r == .copy && exists(R.appendingPathComponent("i1.txt")) && exists(L.appendingPathComponent("i1.txt")), "\(ms)ms", t0: t0)
            let w = k0.collectionView(cv0, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSURL
            check("拖拽（图标）：可以拖出（文件 URL）", w?.isFileURL == true)
            // 选择：⌘A、框选
            t0 = Date()
            app.focusPane(0); await settle(0.3)
            press("a", 0, .command); await settle(0.3)
            check("选择（图标）：⌘A 全选", app.panes[0].tab.selection.count == app.panes[0].tab.display.count && !app.panes[0].tab.selection.isEmpty, "\(app.panes[0].tab.selection.count)", t0: t0)
            app.panes[0].tab.selection = []; await settle(0.3)
            t0 = Date()
            let rr = paneRect(0)
            let a = NSPoint(x: rr.maxX - 8, y: rr.maxY - 4), b = NSPoint(x: rr.minX + 4, y: rr.maxY - 150)
            NSApp.postEvent(mouse(.leftMouseDown, a), atStart: false)
            for i in 1...6 { let f = CGFloat(i) / 6; NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)), atStart: false) }
            NSApp.postEvent(mouse(.leftMouseUp, b), atStart: false)
            await settle(0.6)
            check("选择（图标）：框选", app.panes[0].tab.selection.count >= 2, "选中 \(app.panes[0].tab.selection.count) 项", t0: t0)
            shot("ui-icon-dual")
        } else { check("拖拽（图标）：找到两栏的图标视图", false) }

        // ===== 活动栏跟随鼠标 =====
        await go(0, L, .list); await go(1, R, .list)
        app.focusPane(0); await settle(0.3)
        let leftSel = Set([L.appendingPathComponent("b1.txt")])
        app.panes[0].tab.selection = leftSel; await settle(0.2)
        t0 = Date()
        await moveMouse(to: center(1))
        check("活动栏：鼠标移到右栏 → 右栏成为活动栏（不用点）", app.active == 1 && win.firstResponder === app.responders[1].v, "active=\(app.active)", t0: t0)
        check("活动栏：切换后左栏的选中保持不变", app.panes[0].tab.selection == leftSel)
        press("a", 0, .command); await settle(0.3)
        check("活动栏：鼠标在右栏时 ⌘A 作用于右栏", app.panes[1].tab.selection.count == app.panes[1].tab.display.count && app.panes[0].tab.selection == leftSel, "右=\(app.panes[1].tab.selection.count) 左=\(app.panes[0].tab.selection.count)")
        await moveMouse(to: center(0))
        let backMs = await waitUntil(2) { self.app.active == 0 }
        check("活动栏：鼠标回到左栏 → 左栏活动", app.active == 0, "\(backMs + 250)ms")
        t0 = Date()
        press("c", 8, .command); await moveMouse(to: center(1)); press("v", 9, .command)
        ms = await waitUntil { exists(R.appendingPathComponent("b1 2.txt")) || (exists(R.appendingPathComponent("b1.txt")) && names(R).filter { $0.hasPrefix("b1") }.count >= 2) }
        AppState.conflictOverride = nil
        check("活动栏：左栏 ⌘C → 鼠标移到右栏 ⌘V = 粘贴到右栏", names(R).filter { $0.hasPrefix("b1") }.count >= 2, names(R).sorted().joined(separator: ","), t0: t0)
        await waitUntil { idle() }
        app.focusPane(1); await settle(0.2)
        let r0 = paneRect(0)
        _ = await rightClickMenu(NSPoint(x: r0.maxX - 30, y: r0.minY + 20))
        check("活动栏：在左栏右键 → 左栏先成为活动栏", app.active == 0, "active=\(app.active)")
        TestWindow.mouse = center(1)
        let kd = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        PaneFocus.follow(kd, app: app)
        check("活动栏：按键时以鼠标所在栏为准", app.active == 1)
        // 正在重命名时不抢焦点
        app.focusPane(0); await settle(0.3)
        app.panes[0].tab.selection = [L.appendingPathComponent("b1.txt")]; press("\r", 36); await settle(0.5)
        await moveMouse(to: center(1))
        check("活动栏：就地重命名时鼠标移走不打断编辑", win.firstResponder is NSTextView && app.active == 0)
        press("\u{1b}", 53); await settle(0.4)

        // ===== 基础功能 =====
        await moveMouse(to: center(0)); app.focusPane(0); await settle(0.3)
        let tl = app.panes[0].tab
        // 浏览
        t0 = Date()
        tl.selection = [L.appendingPathComponent("子A").realFileURL]
        if !exists(L.appendingPathComponent("子A")) { try? fm.createDirectory(at: L.appendingPathComponent("子A"), withIntermediateDirectories: true); tl.reload(); await settle(0.5); tl.selection = [L.appendingPathComponent("子A")] }
        await settle(0.2)
        press("\u{F701}", 125, .command); ms = await waitUntil(3) { tl.path.lastPathComponent == "子A" && !tl.loading }
        check("浏览：⌘↓ 打开文件夹", tl.path.lastPathComponent == "子A", "\(ms)ms", t0: t0)
        t0 = Date(); press("[", 33, .command); ms = await waitUntil(3) { tl.path.lastPathComponent == "左" }
        check("浏览：⌘[ 后退", tl.path.lastPathComponent == "左", "\(ms)ms", t0: t0)
        t0 = Date(); press("]", 30, .command); ms = await waitUntil(3) { tl.path.lastPathComponent == "子A" }
        check("浏览：⌘] 前进", tl.path.lastPathComponent == "子A", "\(ms)ms", t0: t0)
        t0 = Date(); press("\u{F700}", 126, .command); ms = await waitUntil(3) { tl.path.lastPathComponent == "左" }
        check("浏览：⌘↑ 上级并选中原文件夹", tl.path.lastPathComponent == "左" && tl.selection.contains { $0.lastPathComponent == "子A" }, "\(ms)ms", t0: t0)
        check("浏览：路径栏显示当前位置", pathText(0).contains("左"), pathText(0))
        t0 = Date(); app.go(R); ms = await waitUntil(3) { tl.path.lastPathComponent == "右" && !tl.loading }
        check("浏览：侧边栏 / 前往（app.go）", tl.path.lastPathComponent == "右", "\(ms)ms", t0: t0)
        await go(0, L, .list)
        // 选择（列表，真实点按）
        if let (tv, c) = tableCoord(0) {
            func rowPt(_ i: Int) -> NSPoint { let rc = tv.rect(ofRow: i); return tv.convert(NSPoint(x: rc.minX + 60, y: rc.midY), to: nil) }
            func clickM(_ p: NSPoint, _ f: NSEvent.ModifierFlags) {
                TestWindow.mouse = p
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(NSEvent.mouseEvent(with: t, location: p, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
                }
            }
            let n = c.rows.count
            t0 = Date(); clickM(rowPt(0), []); await settle(0.3)
            check("选择：单击选中", tl.selection.count == 1, "\(tl.selection.count)", t0: t0)
            clickM(rowPt(min(2, n - 1)), .command); await settle(0.3)
            check("选择：⌘ 点按加选", tl.selection.count == 2, "\(tl.selection.count)")
            clickM(rowPt(1), []); await settle(0.5); clickM(rowPt(n - 1), .shift); await settle(0.5)
            check("选择：⇧ 点按连选", tl.selection.count == n - 1, "\(tl.selection.count)/\(n - 1) 表格=\(tv.selectedRowIndexes.count)")
            press("a", 0, .command); await settle(0.2)
            check("选择：⌘A 全选", tl.selection.count == tl.display.count)
            // 框选（列表从空白处拖）
            tl.selection = []; await settle(0.2)
            let below = tv.convert(NSPoint(x: tv.bounds.width / 2, y: tv.rect(ofRow: n - 1).maxY + 30), to: nil)
            let top = rowPt(0)
            NSApp.postEvent(mouse(.leftMouseDown, below), atStart: false)
            for i in 1...6 { let f = CGFloat(i) / 6; NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: below.x, y: below.y + (top.y - below.y) * f)), atStart: false) }
            NSApp.postEvent(mouse(.leftMouseUp, top), atStart: false); await settle(0.5)
            check("选择（列表）：从空白处框选", tl.selection.count >= 2 && tl.selection.count == tv.selectedRowIndexes.count, "选中 \(tl.selection.count) 项（经 NSApp 事件队列注入按下-拖动-松开，走真实 mouseDown 跟踪循环）")
            // 只框住最后两行：应恰好选中 2 项；⌘ 框选在已有选择上反选
            tl.selection = []; await settle(0.2)
            tv.scrollRowToVisible(n - 1); await settle(0.2)
            let below2 = tv.convert(NSPoint(x: tv.bounds.width / 2, y: tv.rect(ofRow: n - 1).maxY + 30), to: nil)
            let mid = tv.convert(NSPoint(x: tv.bounds.width / 2, y: tv.rect(ofRow: n - 2).midY), to: nil)
            NSApp.postEvent(mouse(.leftMouseDown, below2), atStart: false)
            for i in 1...6 { let f = CGFloat(i) / 6; NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: below2.x, y: below2.y + (mid.y - below2.y) * f)), atStart: false) }
            NSApp.postEvent(mouse(.leftMouseUp, mid), atStart: false); await settle(0.5)
            check("选择（列表）：框选范围准确（只框两行 = 选中 2 项）", tl.selection.count == 2, "\(tl.selection.count)")
            NSApp.postEvent(mouse(.leftMouseDown, below2), atStart: false); NSApp.postEvent(mouse(.leftMouseUp, below2), atStart: false); await settle(0.4)
            check("选择（列表）：点空白处取消选择", tl.selection.isEmpty, "\(tl.selection.count)")
        }
        // 文件操作
        mkfile(L.appendingPathComponent("操作.txt"), "op")
        tl.reload(); await settle(0.5)
        let op = L.appendingPathComponent("操作.txt")
        t0 = Date(); tl.selection = [op]; press("d", 2, .command)
        ms = await waitUntil { shown(0).contains("操作 副本.txt") && idle() }
        check("文件操作：⌘D 复制（「副本」）并立即显示", exists(L.appendingPathComponent("操作 副本.txt")) && shown(0).contains("操作 副本.txt"), "\(ms)ms", t0: t0)
        t0 = Date(); tl.selection = [L.appendingPathComponent("操作 副本.txt")]; press("x", 7, .command)
        await moveMouse(to: center(1)); press("v", 9, .command)
        ms = await waitUntil { exists(R.appendingPathComponent("操作 副本.txt")) && !shown(0).contains("操作 副本.txt") && shown(1).contains("操作 副本.txt") && idle() }
        check("文件操作：⌘X 剪切 → 另一栏 ⌘V 移动", exists(R.appendingPathComponent("操作 副本.txt")) && !exists(L.appendingPathComponent("操作 副本.txt")), "\(ms)ms", t0: t0)
        await moveMouse(to: center(0))
        t0 = Date(); tl.selection = [op]; press("c", 8, .command)
        await moveMouse(to: center(1)); press("v", 9, [.command, .option])
        ms = await waitUntil { exists(R.appendingPathComponent("操作.txt")) && !exists(op) && idle() }
        check("文件操作：⌘C 后 ⌥⌘V = 移动到这里", exists(R.appendingPathComponent("操作.txt")) && !exists(op), "\(ms)ms", t0: t0)
        // 同名冲突
        mkfile(op, "new")
        await moveMouse(to: center(0)); tl.reload(); await settle(0.4)
        tl.selection = [op]; press("c", 8, .command); await moveMouse(to: center(1))
        t0 = Date(); AppState.conflictOverride = (.keepBoth, false); press("v", 9, .command)
        ms = await waitUntil { exists(R.appendingPathComponent("操作 2.txt")) && idle() }
        check("同名冲突：保留两者 → 「操作 2.txt」", exists(R.appendingPathComponent("操作 2.txt")), "\(ms)ms", t0: t0)
        t0 = Date(); AppState.conflictOverride = (.replace, false); press("v", 9, .command)
        ms = await waitUntil { ((try? String(contentsOf: R.appendingPathComponent("操作.txt"), encoding: .utf8)) ?? "") == "new" && idle() }
        check("同名冲突：替换", ((try? String(contentsOf: R.appendingPathComponent("操作.txt"), encoding: .utf8)) ?? "") == "new", "\(ms)ms", t0: t0)
        if case .group(let ops)? = app.undoStack.last { for case .trashed(let p) in ops { trashed += p.map { $0.1 } } }
        t0 = Date(); AppState.conflictOverride = (.stop, false); let before = names(R); press("v", 9, .command)
        await waitUntil { idle() }; await settle(0.3)
        check("同名冲突：停止 → 不改动", names(R) == before, "", t0: t0)
        AppState.conflictOverride = nil
        // 新建文件夹 + 重命名
        await moveMouse(to: center(0)); app.focusPane(0)
        t0 = Date(); press("N", 45, [.command, .shift]); await waitUntil(3) { self.win.firstResponder is NSTextView }
        type("回归新建"); press("\r", 36)
        ms = await waitUntil { exists(L.appendingPathComponent("回归新建")) && shown(0).contains("回归新建") }
        check("文件操作：⇧⌘N 新建文件夹 → 直接命名", exists(L.appendingPathComponent("回归新建")) && shown(0).contains("回归新建"), "\(ms)ms", t0: t0)
        t0 = Date(); tl.selection = [L.appendingPathComponent("回归新建")]; app.focusPane(0); await settle(0.3)
        press("\r", 36); await waitUntil(3) { self.win.firstResponder is NSTextView }
        type("改名后"); press("\r", 36)
        ms = await waitUntil { exists(L.appendingPathComponent("改名后")) && shown(0).contains("改名后") }
        check("文件操作：回车重命名并立即刷新", exists(L.appendingPathComponent("改名后")) && !shown(0).contains("回归新建"), "\(ms)ms", t0: t0)
        // 图标视图里的新建 + 就地重命名
        await go(0, L, .icon); app.focusPane(0); await settle(0.3)
        t0 = Date(); press("N", 45, [.command, .shift]); await waitUntil(3) { self.win.firstResponder is NSTextView }
        let editing = win.firstResponder is NSTextView
        type("图标新建"); press("\r", 36)
        ms = await waitUntil { exists(L.appendingPathComponent("图标新建")) }
        check("文件操作（图标）：⇧⌘N 新建并就地命名", editing && exists(L.appendingPathComponent("图标新建")), "\(ms)ms", t0: t0)
        await go(0, L, .list); app.focusPane(0)
        // 废纸篓 + 撤销
        await waitUntil(3) { (self.win.firstResponder as? NSTableView) != nil }
        t0 = Date(); tl.selection = [L.appendingPathComponent("改名后")]; press("\u{8}", 51, .command)
        ms = await waitUntil { !exists(L.appendingPathComponent("改名后")) && !shown(0).contains("改名后") && idle() }
        check("文件操作：⌘⌫ 移到废纸篓并立即消失", !exists(L.appendingPathComponent("改名后")) && !shown(0).contains("改名后"), "\(ms)ms" + (ms >= 9000 ? " 焦点=\(String(describing: win.firstResponder.map { Swift.type(of: $0) }))" : ""), t0: t0)
        t0 = Date(); press("z", 6, .command)
        ms = await waitUntil { exists(L.appendingPathComponent("改名后")) && shown(0).contains("改名后") && idle() }
        check("文件操作：⌘Z 撤销 → 回到原位并显示", shown(0).contains("改名后"), "\(ms)ms", t0: t0)
        // 预览
        tl.selection = [L.appendingPathComponent("b1.txt")]; app.focusPane(0); await settle(0.2)
        t0 = Date(); press(" ", 49); await settle(0.2)
        check("预览：空格快速查看所选项目", app.controllers[0].qlOpen && app.controllers[0].qlURLs.map { $0.lastPathComponent } == ["b1.txt"], "", t0: t0)
        press(" ", 49); await settle(0.2)
        check("预览：再按空格关闭", !app.controllers[0].qlOpen)
        t0 = Date(); app.showPreview = true; await settle(0.6)
        check("预览：预览面板显示所选项目", app.activeTab.selection.count == 1, "", t0: t0)
        app.showPreview = false; await settle(0.3)
        // 打开方式
        t0 = Date()
        let spec = contextSpec(app: app, tab: tl, pane: 0, urls: [L.appendingPathComponent("b1.txt")])
        var openWith = 0
        for e in spec { if case .sub(let t, let c) = e, t == "打开方式" { openWith = c.filter { if case .item = $0 { return true }; return false }.count } }
        check("右键：「打开方式」列出可用的 App", openWith >= 2, "\(openWith) 项", t0: t0)

        // ===== 访达规则审计：冲突、撤销、无效操作 =====
        await finderRuleTests(&trashed)
        // ===== 访达式进度窗口 =====
        await progressTests()
        // ===== 性能：大批量 =====
        let B = D.appendingPathComponent("批量"), T = D.appendingPathComponent("批量目标")
        try? fm.createDirectory(at: B, withIntermediateDirectories: true); try? fm.createDirectory(at: T, withIntermediateDirectories: true)
        let N = 2000
        let blob = Data(repeating: 7, count: 1024)
        for i in 0..<N { fm.createFile(atPath: B.appendingPathComponent(String(format: "文件%05d.txt", i)).path, contents: blob) }
        let big = Data(repeating: 1, count: 20 << 20)
        for i in 0..<3 { fm.createFile(atPath: B.appendingPathComponent("大文件\(i).bin").path, contents: big) }
        await go(0, B, .list); await go(1, T, .list)
        await waitUntil { self.app.panes[0].tab.display.count == N + 3 }
        perf["listLoad"] = 0
        // 拷贝
        await moveMouse(to: center(0)); press("a", 0, .command); press("c", 8, .command)
        await moveMouse(to: center(1)); await settle(0.5)
        var probe = MainThreadProbe(); probe.start()
        t0 = Date(); press("v", 9, .command)
        ms = await waitUntil(60) { self.idle() && self.app.panes[1].tab.display.count == N + 3 }
        var pr = probe.stop()
        check("性能：拷贝粘贴 \(N + 3) 个文件，主线程最长阻塞 < 50ms", pr.max < 50 && shown(1).count == N + 3, String(format: "耗时 %dms，主线程最长阻塞 %.1fms，p99 %.1fms", ms, pr.max, pr.p99), t0: t0)
        perf["copy"] = Double(ms); perf["copyOp"] = app.lastOpMs; perf["copyMaxBlock"] = pr.max
        // ⌘A 全选 2003 项
        probe = MainThreadProbe(); probe.start(); t0 = Date()
        press("a", 0, .command); await settle(0.5)
        pr = probe.stop()
        check("性能：⌘A 全选 \(N + 3) 项，主线程最长阻塞 < 50ms", pr.max < 50 && app.panes[1].tab.selection.count == N + 3, String(format: "主线程最长阻塞 %.1fms", pr.max), t0: t0)
        perf["selectAllMaxBlock"] = pr.max
        // 移到废纸篓
        probe = MainThreadProbe(); probe.start()
        t0 = Date(); press("\u{8}", 51, .command)
        ms = await waitUntil(120) { self.idle() && self.app.panes[1].tab.display.isEmpty }
        pr = probe.stop()
        check("性能：\(N + 3) 个文件移到废纸篓，主线程最长阻塞 < 50ms", pr.max < 50 && names(T).isEmpty, String(format: "耗时 %dms，主线程最长阻塞 %.1fms", ms, pr.max), t0: t0)
        perf["trash"] = Double(ms); perf["trashOp"] = app.lastOpMs; perf["trashMaxBlock"] = pr.max
        if case .trashed(let p)? = app.undoStack.last { trashed += p.map { $0.1 } }
        app.undoStack.removeAll()
        // 移动（剪切粘贴）
        await moveMouse(to: center(0)); press("a", 0, .command); press("x", 7, .command)
        await moveMouse(to: center(1)); await settle(0.5)
        probe = MainThreadProbe(); probe.start()
        t0 = Date(); press("v", 9, .command)
        ms = await waitUntil(60) { self.idle() && self.app.panes[1].tab.display.count == N + 3 && self.app.panes[0].tab.display.isEmpty }
        pr = probe.stop()
        check("性能：剪切粘贴移动 \(N + 3) 个文件，主线程最长阻塞 < 50ms", pr.max < 50 && names(B).isEmpty, String(format: "耗时 %dms，主线程最长阻塞 %.1fms", ms, pr.max) + (ms >= 59000 ? " [左栏显示 \(app.panes[0].tab.display.count) 磁盘 \(names(B).count)，右栏显示 \(app.panes[1].tab.display.count) 磁盘 \(names(T).count)，idle=\(idle())]" : ""), t0: t0)
        perf["move"] = Double(ms); perf["moveOp"] = app.lastOpMs; perf["moveMaxBlock"] = pr.max
        // 大目录滚动（列表 / 图标）
        if let (tv, _) = tableCoord(1) {
            probe = MainThreadProbe(); probe.start(); t0 = Date()
            var worst = 0.0
            for i in stride(from: 0, to: N, by: 100) { let s = CFAbsoluteTimeGetCurrent(); tv.scrollRowToVisible(i); win.displayIfNeeded(); worst = max(worst, (CFAbsoluteTimeGetCurrent() - s) * 1000); await sleep(0.01) }
            pr = probe.stop()
            check("性能：\(N + 3) 项列表滚动，每帧 < 50ms", worst < 50, String(format: "最慢一帧 %.1fms", worst), t0: t0)
            perf["scrollList"] = worst
        }
        await go(1, T, .icon)
        if let (cv, _) = iconCoord(1) {
            t0 = Date(); var worst = 0.0
            for y in stride(from: 0.0, to: Double(cv.frame.height), by: 600) { let s = CFAbsoluteTimeGetCurrent(); cv.scroll(NSPoint(x: 0, y: y)); win.displayIfNeeded(); worst = max(worst, (CFAbsoluteTimeGetCurrent() - s) * 1000); await sleep(0.01) }
            check("性能：\(N + 3) 项图标视图滚动，每帧 < 50ms", worst < 50, String(format: "最慢一帧 %.1fms", worst), t0: t0)
            perf["scrollIcon"] = worst
            t0 = Date(); let s = CFAbsoluteTimeGetCurrent()
            app.panes[1].tab.selection = Set(app.panes[1].tab.display.prefix(1000).map { $0.url }); win.displayIfNeeded()
            let selMs = (CFAbsoluteTimeGetCurrent() - s) * 1000
            check("性能：图标视图一次选中 1000 项 < 50ms", selMs < 50, String(format: "%.1fms", selMs), t0: t0)
            perf["select1000"] = selMs
        }
        await go(1, T, .list)

        // 清理：只删本测试放进废纸篓的项目
        for u in trashed where u.path.contains("/.Trash") { try? fm.removeItem(at: u) }
        app.undoStack.removeAll()
        await go(0, F, .list); await go(1, F.appendingPathComponent("文件夹A"), .list)
        try? fm.removeItem(at: D)
        await settle(0.5)
    }

    /// 暗色模式快照（与亮色同一状态）
    func darkSnapshots() async {
        win.appearance = NSAppearance(named: .darkAqua); NSApp.appearance = NSAppearance(named: .darkAqua)
        app.dual = true; await settle(1.0)
        let full = win.contentView!.superview!
        shot("dark-pane-list", crop: full.convert(paneRect(1), from: nil))
        app.panes[1].tab.viewMode = .icon; app.objectWillChange.send(); await settle(1.5)
        shot("dark-pane-icon", crop: full.convert(paneRect(1), from: nil))
        win.appearance = NSAppearance(named: .aqua); NSApp.appearance = NSAppearance(named: .aqua)
        app.panes[1].tab.viewMode = .icon; await settle(1.5)
        shot("light-pane-icon", crop: full.convert(paneRect(1), from: nil))
        app.panes[1].tab.viewMode = .list; app.objectWillChange.send(); await settle(0.8)
    }

    func writeChecklist() {
        var md = "| # | 项目 | 结果 | 实测耗时 | 说明 |\n|---|---|---|---|---|\n"
        for (i, r) in results.enumerated() { md += "| \(i + 1) | \(r.name) | \(r.ok ? "✅ 通过" : "❌ 失败") | \(r.ms) ms | \(r.detail.replacingOccurrences(of: "|", with: "/")) |\n" }
        try? md.write(to: TestEnv.out.appendingPathComponent("checklist.md"), atomically: true, encoding: .utf8)
        let p = perf.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.sorted().joined(separator: " ")
        try? p.write(to: TestEnv.out.appendingPathComponent("perf.txt"), atomically: true, encoding: .utf8)
    }

    /// 用户反馈：同卷拖动被拷贝、同名时报「已存在」错误。这里逐条按访达规则验证（两栏双向）。
    func progressTests() async {
        let D = TestEnv.fixture.realFileURL.appendingPathComponent("进度"), S = D.appendingPathComponent("源"), T = D.appendingPathComponent("目标")
        try? fm.removeItem(at: D)
        for d in [S, T] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let big = S.appendingPathComponent("big.bin")
        // 64 MB 实际数据（不是稀疏文件）
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        fm.createFile(atPath: big.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: big) { for _ in 0..<64 { h.write(chunk) }; try? h.close() }
        mkfile(S.appendingPathComponent("small.txt"), "s")
        let c = app.center
        FileOps.noClone = true
        defer { FileOps.noClone = false; FileOps.testThrottleMs = 0 }
        // 1. 瞬间完成的操作不弹进度窗口
        var t0 = Date(); let before = c.shownCount
        app.transfer([S.appendingPathComponent("small.txt")], to: T, mode: .copy)
        var ms = await waitUntil { exists(T.appendingPathComponent("small.txt")) && idle() }
        await settle(0.9)
        check("进度窗口：瞬间完成的拷贝不弹出进度窗口", c.shownCount == before && !c.isPanelVisible, "\(ms)ms", t0: t0)
        // 2. 大文件拷贝：0.75 秒后出现，标题 / 进度 / 字节数 / 剩余时间
        FileOps.testThrottleMs = 150
        t0 = Date()
        app.transfer([big], to: T, mode: .copy)
        ms = await waitUntil(5) { c.isPanelVisible }
        let shownAfter = Date().timeIntervalSince(t0)
        check("进度窗口：大文件拷贝时出现（不早于 0.75 秒）", c.isPanelVisible && shownAfter >= 0.7, String(format: "%.2fs", shownAfter), t0: t0)
        await sleep(1.8)
        let p = c.ops.first
        let title = p.map { OpCenter.title($0) } ?? "", detail = p.map { OpCenter.detail($0) } ?? ""
        check("进度窗口：标题「正在将“big.bin”拷贝到“目标”」", title == "正在将“big.bin”拷贝到“目标”", title)
        check("进度窗口：明细「已拷贝 x，共 64 MB — 约剩…」", detail.hasPrefix("已拷贝 ") && detail.contains("共 67.1 MB") && detail.contains("—"), detail)
        let bd = p?.bytesDone ?? 0
        check("进度窗口：字节进度在增长且没有完成", bd > 0 && bd < 64 << 20, "\(bd)")
        check("状态栏：显示百分比", (app.busyText ?? "").contains("%"), app.busyText ?? "nil")
        check("进度窗口：标题栏是「拷贝」", c.panelWindow?.title == "拷贝", c.panelWindow?.title ?? "nil")
        // 两个操作同时：叠在同一个窗口里
        app.transfer([S.appendingPathComponent("small.txt")], to: S.appendingPathComponent("..").standardizedFileURL.appendingPathComponent("目标"), mode: .copy)
        await sleep(0.3)
        check("进度窗口：多个操作叠在一起显示，后一个显示「等待中…」", c.ops.count == 2 && OpCenter.detail(c.ops[1]) == "等待中…", c.ops.count == 2 ? OpCenter.detail(c.ops[1]) : "\(c.ops.count)")
        // 截图（亮 / 暗）
        for (n, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: ProgressList(center: c))
            let sz = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: max(460, sz.width), height: max(60, sz.height))
            let pw = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            pw.appearance = NSAppearance(named: ap); pw.contentView = host
            host.layoutSubtreeIfNeeded(); await sleep(0.3); host.layoutSubtreeIfNeeded(); host.display()
            shot("progress-\(n)", view: host)
            pw.contentView = nil
        }
        let okShots = ["light", "dark"].allSatisfy { ((try? fm.attributesOfItem(atPath: TestEnv.out.appendingPathComponent("progress-\($0).png").path)[.size] as? Int) ?? 0) > 2000 }
        check("进度窗口：亮色 / 暗色截图", okShots)
        // 3. 停止：不留半截文件，窗口消失
        t0 = Date(); p?.cancel()
        ms = await waitUntil(10) { idle() && c.ops.isEmpty }
        await settle(0.3)
        check("进度窗口：点停止 → 停止拷贝、不留半截文件、原件还在", !exists(T.appendingPathComponent("big.bin")) && exists(big) && app.alert == nil, "\(ms)ms", t0: t0)
        check("进度窗口：操作结束后窗口消失", !c.isPanelVisible)
        // 4. 完整拷贝：完成后消失，内容一致
        FileOps.testThrottleMs = 15
        t0 = Date()
        app.transfer([big], to: T, mode: .copy)
        ms = await waitUntil(30) { idle() && c.ops.isEmpty }
        await settle(0.3)
        let sz = (try? fm.attributesOfItem(atPath: T.appendingPathComponent("big.bin").path)[.size] as? Int) ?? 0
        check("进度窗口：拷贝完成后自动消失，文件完整", !c.isPanelVisible && sz == 64 << 20 && fm.contentsEqual(atPath: big.path, andPath: T.appendingPathComponent("big.bin").path), "\(ms)ms", t0: t0)
        // 4b. 回归：单个文件夹（含 0 字节文件、符号链接、包）1/1 项拷贝能完成，字节数对得上，状态不会挂住
        FileOps.testThrottleMs = 0
        let K = S.appendingPathComponent("素材"), pkg = K.appendingPathComponent("X.app/Contents")
        try? fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        mkfile(pkg.appendingPathComponent("Info.plist"), "plist"); fm.createFile(atPath: K.appendingPathComponent("空.txt").path, contents: Data())
        try? fm.createSymbolicLink(atPath: K.appendingPathComponent("链接").path, withDestinationPath: "/nonexistent/目标")
        try? chunk.write(to: K.appendingPathComponent("a.bin"))
        t0 = Date()
        let before2 = c.shownCount
        app.transfer([K], to: T, mode: .copy)
        let rp = c.ops.last
        ms = await waitUntil(10) { idle() && c.ops.isEmpty }
        let K2 = T.appendingPathComponent("素材")
        check("回归：拷贝 1/1 个文件夹（0 字节文件、坏符号链接、包）能完成，状态栏不挂住", idle() && exists(K2.appendingPathComponent("空.txt")) && FileOps.isSymlink(K2.appendingPathComponent("链接")) && exists(K2.appendingPathComponent("X.app/Contents/Info.plist")) && app.alert == nil, "\(ms)ms", t0: t0)
        check("回归：文件夹拷贝的字节数 = 总字节数", rp.map { $0.bytesTotal == $0.bytesDone && $0.bytesTotal == (1 << 20) + 5 } ?? false, rp.map { "\($0.bytesDone)/\($0.bytesTotal)" } ?? "nil")
        _ = before2
        // 5. 文案
        let q = OpProgress(); q.kind = .move; q.total = 3; q.destName = "备份"; q.markRunning()
        check("进度窗口：移动多个项目的标题", OpCenter.title(q) == "正在将 3 个项目移动到“备份”", OpCenter.title(q))
        q.step()
        check("进度窗口：移动按项目数显示", OpCenter.detail(q) == "已移动 1 个项目，共 3 个", OpCenter.detail(q))
        let tq = OpProgress(); tq.kind = .trash; tq.total = 1; tq.firstName = "a.txt"
        check("进度窗口：移到废纸篓的标题", OpCenter.title(tq) == "正在将“a.txt”移到废纸篓", OpCenter.title(tq))
        check("进度窗口：剩余时间文案", OpCenter.eta(10) == "约剩 10 秒" && OpCenter.eta(150) == "约剩 3 分钟" && OpCenter.eta(2) == "马上就好")
        // 看门狗：长时间没有进展要说出来
        let w = OpProgress(); w.kind = .copy; w.total = 1; w.markRunning(); w.bytesTotal = 100; w.addBytes(10)
        let d = OpCenter.detail(w, now: Date().addingTimeInterval(40))
        check("进度窗口：长时间没有进展时提示（不再静默卡住）", d.contains("没有进展"), d)
        try? fm.removeItem(at: D)
    }
    func finderRuleTests(_ trashed: inout [URL]) async {
        let D = TestEnv.fixture.realFileURL.appendingPathComponent("访达规则"), L = D.appendingPathComponent("甲"), R = D.appendingPathComponent("乙")
        try? fm.removeItem(at: D)
        for d in [L, R, L.appendingPathComponent("子"), R.appendingPathComponent("收件")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for n in ["run.mp3", "x.txt", "y.txt"] { mkfile(L.appendingPathComponent(n), "L-" + n) }
        for n in ["run.mp3", "x.txt", "y.txt"] { mkfile(R.appendingPathComponent(n), "R-" + n) }
        mkfile(R.appendingPathComponent("r1.txt"), "r1")
        func content(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        await go(0, L, .list); await go(1, R, .list)
        guard let (tv0, c0) = tableCoord(0), let (tv1, c1) = tableCoord(1) else { check("访达规则：找到两栏表格", false); return }
        DragMods.override = []
        // 1. 同卷拖动 = 移动（右 → 左）
        var t0 = Date()
        var d = FakeDrag([R.appendingPathComponent("r1.txt")])
        var op = c0.tableView(tv0, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
        _ = c0.tableView(tv0, acceptDrop: d, row: -1, dropOperation: .on)
        var ms = await waitUntil { exists(L.appendingPathComponent("r1.txt")) && !exists(R.appendingPathComponent("r1.txt")) && idle() }
        check("访达规则：同卷拖动 = 移动（右 → 左，不留原件）", op == .move && exists(L.appendingPathComponent("r1.txt")) && !exists(R.appendingPathComponent("r1.txt")), "op=\(op.rawValue) \(ms)ms", t0: t0)
        // 2. ⌘Z 撤销移动 → 回到原处
        t0 = Date(); app.undo()
        ms = await waitUntil { exists(R.appendingPathComponent("r1.txt")) && !exists(L.appendingPathComponent("r1.txt")) && shown(1).contains("r1.txt") && idle() }
        check("访达规则：⌘Z 撤销移动 → 回到原文件夹", exists(R.appendingPathComponent("r1.txt")) && !exists(L.appendingPathComponent("r1.txt")) && shown(1).contains("r1.txt"), "\(ms)ms", t0: t0)
        // 3. 拖到侧边栏 / 路径栏（SwiftUI 放下目标）同卷 = 移动
        t0 = Date()
        _ = app.dropProviders([NSItemProvider(object: R.appendingPathComponent("r1.txt") as NSURL)], to: L.appendingPathComponent("子"))
        ms = await waitUntil { exists(L.appendingPathComponent("子/r1.txt")) && idle() }
        check("访达规则：拖到侧边栏 / 路径栏文件夹 = 移动", exists(L.appendingPathComponent("子/r1.txt")) && !exists(R.appendingPathComponent("r1.txt")), "\(ms)ms", t0: t0)
        // 4. 冲突：左 → 右移动同名文件，保留两者 → 「run 2.mp3」，原件移走
        for (dirName, src, dst, cs, cd) in [("左 → 右", L, R, c1, tv1), ("右 → 左", R, L, c0, tv0)] {
            t0 = Date(); AppState.conflictOverride = (.keepBoth, false)
            d = FakeDrag([src.appendingPathComponent("run.mp3")])
            op = cs.tableView(cd, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            _ = cs.tableView(cd, acceptDrop: d, row: -1, dropOperation: .on)
            ms = await waitUntil { exists(dst.appendingPathComponent("run 2.mp3")) && idle() }
            check("访达规则：同名冲突（拖动 \(dirName)）保留两者 → 「run 2.mp3」，不报错", op == .move && exists(dst.appendingPathComponent("run 2.mp3")) && exists(dst.appendingPathComponent("run.mp3")) && !exists(src.appendingPathComponent("run.mp3")) && app.alert == nil, "\(ms)ms", t0: t0)
            // 放回去，下一轮用
            try? fm.moveItem(at: dst.appendingPathComponent("run 2.mp3"), to: src.appendingPathComponent("run.mp3"))
        }
        // 5. 冲突：替换（被替换的进废纸篓，可撤销）/ 停止（不改动）——两个方向
        t0 = Date(); AppState.conflictOverride = (.replace, false)
        d = FakeDrag([L.appendingPathComponent("x.txt")]); _ = c1.tableView(tv1, validateDrop: d, proposedRow: -1, proposedDropOperation: .on); _ = c1.tableView(tv1, acceptDrop: d, row: -1, dropOperation: .on)
        ms = await waitUntil { !exists(L.appendingPathComponent("x.txt")) && idle() }
        check("访达规则：同名冲突 替换（左 → 右）", content(R.appendingPathComponent("x.txt")) == "L-x.txt" && !exists(L.appendingPathComponent("x.txt")), "\(ms)ms", t0: t0)
        if case .group(let ops)? = app.undoStack.last { for case .trashed(let p) in ops { trashed += p.map { $0.1 } } }
        t0 = Date(); AppState.conflictOverride = (.stop, false)
        d = FakeDrag([R.appendingPathComponent("y.txt")]); _ = c0.tableView(tv0, validateDrop: d, proposedRow: -1, proposedDropOperation: .on); _ = c0.tableView(tv0, acceptDrop: d, row: -1, dropOperation: .on)
        ms = await waitUntil { idle() }; await settle(0.3)
        check("访达规则：同名冲突 停止（右 → 左）→ 两边都不变", content(L.appendingPathComponent("y.txt")) == "L-y.txt" && content(R.appendingPathComponent("y.txt")) == "R-y.txt", "\(ms)ms", t0: t0)
        // 6. 剪切粘贴同名冲突（⌘X → 另一栏 ⌘V）也走同一个对话框
        t0 = Date(); AppState.conflictOverride = (.keepBoth, false)
        app.focusPane(0); tlSelect(0, [L.appendingPathComponent("y.txt")]); press("x", 7, .command)
        await moveMouse(to: center(1)); app.focusPane(1); await settle(0.3); press("v", 9, .command)
        ms = await waitUntil { exists(R.appendingPathComponent("y 2.txt")) && idle() }
        check("访达规则：剪切粘贴同名 → 保留两者「y 2.txt」，不报错", exists(R.appendingPathComponent("y 2.txt")) && !exists(L.appendingPathComponent("y.txt")) && app.alert == nil, "\(ms)ms", t0: t0)
        AppState.conflictOverride = nil
        // 7. 冲突对话框：文字、按钮顺序与访达一致
        let a1 = AppState.conflictAlert(name: "run.mp3", move: true, multi: true)
        check("访达规则：冲突对话框文字（移动）", a1.messageText == "此位置已经存在名称为“run.mp3”的项目。" && a1.informativeText == "你要使用正在移动的项目进行替换吗？", a1.messageText + " / " + a1.informativeText)
        check("访达规则：按钮 保留两者 | 停止 | 替换（替换为默认，Esc = 停止），多个冲突有「应用到全部」",
              a1.buttons.map { $0.title } == ["替换", "停止", "保留两者"] && a1.buttons[1].keyEquivalent == "\u{1b}" && a1.showsSuppressionButton && a1.suppressionButton?.title == "应用到全部",
              a1.buttons.map { $0.title }.reversed().joined(separator: " | "))
        let a2 = AppState.conflictAlert(name: "a.txt", move: false, multi: false)
        check("访达规则：拷贝时说「正在拷贝的项目」；只有一个冲突时没有「应用到全部」", a2.informativeText == "你要使用正在拷贝的项目进行替换吗？" && !a2.showsSuppressionButton)
        // 8. 多个冲突才显示「应用到全部」（按实际冲突数量判断）
        mkfile(L.appendingPathComponent("m1.txt")); mkfile(L.appendingPathComponent("m2.txt")); mkfile(R.appendingPathComponent("m1.txt")); mkfile(R.appendingPathComponent("m2.txt"))
        let p = OpProgress(); var multiSeen: [Bool] = []
        _ = FileOps.transfer([L.appendingPathComponent("m1.txt"), L.appendingPathComponent("m2.txt")], to: R, mode: .copy, progress: p, resolve: { _, _ in multiSeen.append(p.conflictsLeft > 1); return (.skip, false) })
        let p2 = OpProgress(); var single: [Bool] = []
        _ = FileOps.transfer([L.appendingPathComponent("m1.txt")], to: R, mode: .copy, progress: p2, resolve: { _, _ in single.append(p2.conflictsLeft > 1); return (.skip, false) })
        check("访达规则：2 个冲突时第一个对话框带「应用到全部」，最后一个和单个冲突时不带", multiSeen == [true, false] && single == [false], "\(multiSeen) \(single)")
        // 9. 无效操作：拖回原文件夹、把文件夹拖进它自己、同一文件夹剪切粘贴
        let rowSub = c0.rows.firstIndex { if case .item(let it) = $0 { return it.name == "子" }; return false } ?? -1
        op = c0.tableView(tv0, validateDrop: FakeDrag([L.appendingPathComponent("子")]), proposedRow: rowSub, proposedDropOperation: .on)
        check("访达规则：把文件夹拖到它自己上 → 拒绝", rowSub >= 0 && op == [], "op=\(op.rawValue)")
        op = c0.tableView(tv0, validateDrop: FakeDrag([L.appendingPathComponent("run.mp3")]), proposedRow: -1, proposedDropOperation: .on)
        check("访达规则：拖到它所在的文件夹 → 不做任何事", op == [], "op=\(op.rawValue)")
        t0 = Date()
        let before = names(L)
        await moveMouse(to: center(0)); app.focusPane(0); tlSelect(0, [L.appendingPathComponent("run.mp3")]); press("x", 7, .command); press("v", 9, .command)
        await waitUntil(2) { self.idle() }; await settle(0.4)
        check("访达规则：剪切后在同一文件夹粘贴 → 不做任何事（不产生副本）", names(L) == before && app.alert == nil, "\(names(L).sorted())", t0: t0)
        // 10. 拷贝后 ⌘Z → 拷贝出的项目被撤销
        t0 = Date(); DragMods.override = .option
        d = FakeDrag([L.appendingPathComponent("run.mp3")]); _ = c1.tableView(tv1, validateDrop: d, proposedRow: -1, proposedDropOperation: .on); _ = c1.tableView(tv1, acceptDrop: d, row: -1, dropOperation: .on)
        DragMods.override = []
        await waitUntil { exists(R.appendingPathComponent("run 2.mp3")) && self.idle() }
        app.undo()
        ms = await waitUntil { !exists(R.appendingPathComponent("run 2.mp3")) && self.idle() }
        trashed += app.lastUndoTrashed
        check("访达规则：⌥ 拷贝后 ⌘Z → 拷贝被撤销，原件还在", !exists(R.appendingPathComponent("run 2.mp3")) && exists(L.appendingPathComponent("run.mp3")), "\(ms)ms", t0: t0)
        // 11. 重命名为已有名称 → 访达的提示，不改动
        t0 = Date(); app.alert = nil
        app.rename(L.appendingPathComponent("run.mp3"), to: "子")
        await settle(0.3)
        check("访达规则：重命名为已有名称 → 提示「名称“子”已被使用。请选取一个不同的名称。」", (app.alert?.message ?? "").contains("名称“子”已被使用。请选取一个不同的名称。") && exists(L.appendingPathComponent("run.mp3")), app.alert?.message ?? "无提示", t0: t0)
        app.alert = nil
    }
    func tlSelect(_ pane: Int, _ urls: [URL]) { let t = app.panes[pane].tab; t.selection = Set(urls.map { $0.standardizedFileURL }); t.anchor = urls.first }
}
