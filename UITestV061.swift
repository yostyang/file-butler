import SwiftUI
import AppKit

/// v0.6.1 验收问题的界面测试：
/// 1 多选拖拽在各种显示方式之间全部移动；2 鼠标悬停不改变位置；3 路径栏右键「拷贝路径」；
/// 4 分栏视图横向滚动、每栏不压缩；5 分栏预览居中；6 未装载磁盘的最近访问不显示；7 文件夹快速查看；8 分栏视图方向键。
/// 只在 /tmp/fb-ui/v061 里操作；拖放走和真实拖放相同的放下代码（离屏窗口里无法发起真正的系统拖动会话）。
extension UITestRunner {
    /// 列表视图拖出时写入拖动剪贴板的内容（和真实拖动一样：每个选中行一个 NSURL）
    func tableDragPasteboard(_ pane: Int) -> NSPasteboard? {
        guard let (tv, c) = tableCoord(pane) else { return nil }
        let pb = NSPasteboard(name: NSPasteboard.Name("fb-test-multidrag")); pb.clearContents()
        pb.writeObjects(tv.selectedRowIndexes.compactMap { c.tableView(tv, pasteboardWriterForRow: $0) })
        return pb
    }
    func urlPasteboard(_ urls: [URL]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("fb-test-multidrag")); pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL }); return pb
    }
    /// 分栏视图的横向滚动视图：栏内最宽、宽度不超过这一栏的 NSScrollView
    func columnScrollView(_ pane: Int) -> NSScrollView? {
        // 这一栏里横向可滚动（内容比可见宽度宽）、高度占满的那个滚动视图
        let r = paneRect(pane); var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.window === win, !s.isHiddenOrHasHiddenAncestor, let d = s.documentView {
                let f = s.convert(s.bounds, to: nil)
                if f.height > 300, f.width > 150, d.frame.width > s.contentSize.width + 50, r.isEmpty || f.intersects(r),
                   best.map({ d.frame.width > ($0.documentView?.frame.width ?? 0) }) ?? true { best = s }
            }
            v.subviews.forEach(walk)
        }
        if let root = win.contentView?.superview { walk(root) }
        return best
    }
    func markers(_ pane: Int, bg: Bool? = nil, seg: Bool = false) -> [ItemMarker] {
        let t = app.panes[pane].tab
        return RightClick.markers.allObjects.filter { $0.window === win && $0.tab === t && $0.seg == seg && (bg == nil || $0.bg == bg!) && !$0.isHiddenOrHasHiddenAncestor && !MultiDrag.visibleFrame($0).isEmpty }
    }
    func mid(_ v: NSView) -> NSPoint { let r = MultiDrag.visibleFrame(v); return NSPoint(x: r.midX, y: r.midY) }
    func arrow(_ code: UInt16) {
        let ch: [UInt16: Int] = [123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700]
        press(String(UnicodeScalar(ch[code]!)!), code)
    }

    func v061Tests() async {
        let F = TestEnv.fixture.realFileURL
        // 结束时两栏回到进来时的位置和显示方式（后面的深色 / 浅色截图拍的是右栏）
        let entry = (0..<2).map { (app.panes[$0].tab.path, app.panes[$0].tab.viewMode) }
        let D = F.appendingPathComponent("v061")
        try? fm.removeItem(at: D)
        let S = D.appendingPathComponent("下载"), T = D.appendingPathComponent("目标"), Sub = T.appendingPathComponent("子目录")
        let Empty = D.appendingPathComponent("空文件夹"), K = D.appendingPathComponent("键盘")
        for d in [S, T, Sub, Empty, K, K.appendingPathComponent("a文件夹")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let dmgs = (1...11).map { String(format: "安装包%02d.dmg", $0) }
        for n in dmgs { mkfile(S.appendingPathComponent(n), n) }
        for n in ["内1.txt", "内2.txt"] { mkfile(K.appendingPathComponent("a文件夹/" + n), n) }
        for n in ["b.txt", "c.txt"] + (1...9).map({ "d\($0).txt" }) { mkfile(K.appendingPathComponent(n), n) }
        app.dual = true; app.showPreview = false; app.shelf.clear(); app.shelf.visible = false; DragMods.override = []
        await settle(0.4)
        var trashed: [URL] = []
        func allIn(_ d: URL) -> Bool { dmgs.allSatisfy { exists(d.appendingPathComponent($0)) } }
        func noneIn(_ d: URL) -> Bool { dmgs.allSatisfy { !exists(d.appendingPathComponent($0)) } }
        func count(_ d: URL) -> Int { names(d).filter { $0.hasSuffix(".dmg") }.count }
        func undoBack() async -> Bool {
            app.undo(); await waitUntil(8) { allIn(S) && self.idle() }
            trashed += app.lastUndoTrashed; await settle(0.3); return allIn(S)
        }
        let first = [NSItemProvider(object: S.appendingPathComponent(dmgs[0]) as NSURL)]   // SwiftUI 的 itemProviders 只给出第一个项目

        // ===== 1. 多选拖拽 =====
        await go(0, S, .list); await go(1, T, .column)
        await tableSelect(0, dmgs)
        let sel = app.panes[0].tab.selection.count
        let pb = tableDragPasteboard(0) ?? urlPasteboard([])
        check("多选拖拽：列表选中 11 个 .dmg，拖动剪贴板里有 11 个文件", sel == 11 && fileURLs(pb).count == 11, "选中 \(sel)，剪贴板 \(fileURLs(pb).count)")
        var t0 = Date()
        FinderDrop.perform(app: app, dir: app.panes[1].tab.path, pasteboard: pb, providers: first)
        var ms = await waitUntil(10) { allIn(T) && self.idle() }
        check("多选拖拽：列表 → 分栏视图的文件夹栏，11 个全部移动（同一卷）", allIn(T) && noneIn(S), "目标 \(count(T)) 个，原处 \(count(S)) 个，\(ms)ms", t0: t0)
        var ok = await undoBack()
        check("多选拖拽：⌘Z 一次撤销，11 个全部回到原处", ok && noneIn(T), "原处 \(count(S)) 个")

        // 最后一栏右侧的空白：放进最深的那个文件夹
        app.controllers[1].columnSelect(Sub, at: 0); await settle(0.6)
        let tail = markers(1, bg: true).filter { $0.url?.standardizedFileURL.path == Sub.standardizedFileURL.path }
        t0 = Date()
        await tableSelect(0, dmgs)
        FinderDrop.perform(app: app, dir: app.panes[1].tab.columnChain.last ?? T, pasteboard: tableDragPasteboard(0) ?? pb, providers: first)
        ms = await waitUntil(10) { allIn(Sub) && self.idle() }
        check("多选拖拽：列表 → 分栏视图最后一栏右侧空白，11 个全部移进最深的文件夹", tail.count >= 2 && allIn(Sub) && noneIn(S), "空白区标记 \(tail.count) 个，子目录 \(count(Sub)) 个，\(ms)ms", t0: t0)
        ok = await undoBack(); check("多选拖拽：撤销（最后一栏空白）", ok)

        // 文件夹行
        app.panes[1].tab.columnChain = []; app.panes[1].tab.selection = []; await settle(0.5)
        t0 = Date()
        await tableSelect(0, dmgs)
        FinderDrop.perform(app: app, dir: Sub, pasteboard: tableDragPasteboard(0) ?? pb, providers: first)
        ms = await waitUntil(10) { allIn(Sub) && self.idle() }
        check("多选拖拽：列表 → 分栏视图里的文件夹行，11 个全部放进该文件夹", allIn(Sub) && noneIn(S), "子目录 \(count(Sub)) 个，\(ms)ms", t0: t0)
        ok = await undoBack(); check("多选拖拽：撤销（文件夹行）", ok)

        // ⌥ = 拷贝
        t0 = Date(); DragMods.override = .option
        await tableSelect(0, dmgs)
        FinderDrop.perform(app: app, dir: T, pasteboard: tableDragPasteboard(0) ?? pb, providers: first)
        ms = await waitUntil(10) { allIn(T) && self.idle() }
        DragMods.override = []
        check("多选拖拽：按 ⌥ 拷贝 11 个，原文件保留", allIn(T) && allIn(S), "目标 \(count(T)) 个，原处 \(count(S)) 个，\(ms)ms", t0: t0)
        app.undo(); await waitUntil(8) { noneIn(T) && self.idle() }; trashed += app.lastUndoTrashed
        check("多选拖拽：撤销拷贝（拷贝出的文件移到废纸篓）", noneIn(T) && allIn(S))

        // 列表 → 图标（AppKit 图标视图）
        await go(1, T, .icon)
        if let (cv, k) = iconCoord(1) {
            t0 = Date()
            let d = FakeDrag(dmgs.map { S.appendingPathComponent($0) })
            var ip = NSIndexPath(forItem: 0, inSection: 0); var op: NSCollectionView.DropOperation = .before
            let r = k.collectionView(cv, validateDrop: d, proposedIndexPath: &ip, dropOperation: &op)
            _ = k.collectionView(cv, acceptDrop: d, indexPath: ip as IndexPath, dropOperation: op)
            ms = await waitUntil(10) { allIn(T) && self.idle() }
            check("多选拖拽：列表 → 图标视图，11 个全部移动", r == .move && allIn(T) && noneIn(S), "目标 \(count(T)) 个，\(ms)ms", t0: t0)
            ok = await undoBack(); check("多选拖拽：撤销（图标视图）", ok)
        } else { check("多选拖拽：列表 → 图标视图", false, "找不到图标视图") }

        // 分栏 → 列表：分栏视图里多选后按住其中一项拖动 = 拖动全部选中项目
        await go(0, S, .column); await go(1, T, .list)
        let tS = app.panes[0].tab
        tS.selection = Set(tS.items.filter { $0.name.hasSuffix(".dmg") }.map { $0.url }); tS.anchor = tS.items.first?.url
        await settle(0.5)
        let rowM = markers(0, bg: false).first { $0.url?.lastPathComponent == dmgs[2] }
        let hit = rowM.flatMap { MultiDrag.marker(at: mid($0), in: win) }
        let colURLs = MultiDrag.urlsToDrag(tS.items.first { $0.name == dmgs[2] }?.url ?? S, tab: tS)
        check("多选拖拽：分栏视图按下选中的行 → 识别到这一项，拖动内容是全部 11 个", hit?.url?.lastPathComponent == dmgs[2] && colURLs.count == 11, "识别 \(hit?.url?.lastPathComponent ?? "无")，拖动 \(colURLs.count) 个")
        let one = MultiDrag.urlsToDrag(S.appendingPathComponent("不在选择里.txt"), tab: tS)
        check("多选拖拽：按住未选中的项目只拖它自己（访达）", one.count == 1)
        if let (tv, c) = tableCoord(1) {
            t0 = Date()
            let d = FakeDrag(colURLs)
            let op = c.tableView(tv, validateDrop: d, proposedRow: -1, proposedDropOperation: .on)
            _ = c.tableView(tv, acceptDrop: d, row: -1, dropOperation: .on)
            ms = await waitUntil(10) { allIn(T) && self.idle() }
            check("多选拖拽：分栏 → 列表，11 个全部移动", op == .move && allIn(T) && noneIn(S), "目标 \(count(T)) 个，\(ms)ms", t0: t0)
            ok = await undoBack(); check("多选拖拽：撤销（分栏 → 列表）", ok)
        } else { check("多选拖拽：分栏 → 列表", false, "找不到列表") }

        // 画廊：作为拖出方、作为放下目标
        await go(0, S, .gallery); await go(1, T, .gallery)
        let tG = app.panes[0].tab
        tG.selection = Set(tG.display.map { $0.url }); await settle(0.4)
        let gURLs = MultiDrag.urlsToDrag(tG.display.first?.url ?? S, tab: tG)
        t0 = Date()
        FinderDrop.perform(app: app, dir: app.panes[1].tab.path, pasteboard: urlPasteboard(gURLs), providers: first)
        ms = await waitUntil(10) { allIn(T) && self.idle() }
        check("多选拖拽：画廊 → 画廊，11 个全部移动", gURLs.count == 11 && allIn(T) && noneIn(S), "拖动 \(gURLs.count) 个，目标 \(count(T)) 个，\(ms)ms", t0: t0)
        ok = await undoBack(); check("多选拖拽：撤销（画廊）", ok)

        // ===== 2. 分栏视图：鼠标悬停不改变位置 / 选择 =====
        await go(0, S, .list); await go(1, K, .column)
        app.controllers[1].columnSelect(K.appendingPathComponent("a文件夹"), at: 0); await settle(0.6)
        func state(_ i: Int) -> String { let t = app.panes[i].tab; return t.path.path + "|" + t.columnChain.map { $0.lastPathComponent }.joined(separator: ",") + "|" + t.selection.map { $0.lastPathComponent }.sorted().joined(separator: ",") }
        let before = (state(0), state(1))
        let hoverTargets = Array(markers(1).prefix(10))
        for m in hoverTargets { await moveMouse(to: mid(m)) }
        let r1 = paneRect(1)
        for x in stride(from: r1.minX + 20, to: r1.maxX - 10, by: 60) { await moveMouse(to: NSPoint(x: x, y: r1.midY)) }
        await settle(0.4)
        check("分栏视图：鼠标在各栏上移动不打开、不选中文件夹（两栏位置和选择不变）", (state(0), state(1)) == before && hoverTargets.count >= 3, "经过 \(hoverTargets.count) 个项目；\(state(1))")
        check("分栏视图：活动栏仍跟随鼠标（快捷键作用于鼠标下的栏）", app.active == 1, "活动栏 \(app.active)，第一响应者 \(String(describing: win.firstResponder.map { Swift.type(of: $0) }))")

        // ===== 8. 分栏视图：方向键 =====
        let tK = app.panes[1].tab
        tK.columnChain = []; tK.selection = []; tK.anchor = nil
        app.focusPane(1); await settle(0.4)
        func selName() -> String { tK.selection.map { $0.lastPathComponent }.sorted().joined(separator: ",") }
        func chain() -> String { tK.columnChain.map { $0.lastPathComponent }.joined(separator: "/") }
        let fr0 = String(describing: win.firstResponder.map { Swift.type(of: $0) })
        arrow(125); await settle(0.4)
        check("分栏视图：↓ 选中第一项（文件夹）并打开它的下一栏", selName() == "a文件夹" && chain() == "a文件夹", "\(selName()) [\(chain())] 第一响应者 \(fr0)，活动栏 \(app.active)")
        arrow(125); await settle(0.4)
        check("分栏视图：↓ 移到下一项，右边的栏关闭", selName() == "b.txt" && chain() == "", "\(selName()) [\(chain())]")
        arrow(126); await settle(0.4)
        check("分栏视图：↑ 回到上一项", selName() == "a文件夹" && chain() == "a文件夹", "\(selName()) [\(chain())]")
        arrow(124); await waitUntil(3) { selName() == "内1.txt" }; await settle(0.3)
        check("分栏视图：→ 进入文件夹，选中下一栏第一项", selName() == "内1.txt" && chain() == "a文件夹", "\(selName()) [\(chain())]")
        arrow(125); await settle(0.4)
        check("分栏视图：在第二栏里 ↓", selName() == "内2.txt", selName())
        arrow(123); await settle(0.4)
        check("分栏视图：← 回到上一栏，选中父文件夹", selName() == "a文件夹" && chain() == "a文件夹", "\(selName()) [\(chain())]")
        press("c", 8); await settle(0.4)
        check("分栏视图：键入名称选择（c → c.txt）", selName() == "c.txt", selName())
        // 其他显示方式的 ↑↓
        await go(1, K, .list); await tableSelect(1, ["b.txt"]); app.focusPane(1); await settle(0.3)
        arrow(125); await settle(0.3)
        check("列表视图：↓ 移到下一项", selName() == "c.txt", selName())
        arrow(126); await settle(0.3)
        check("列表视图：↑ 回到上一项", selName() == "b.txt", selName())
        await go(1, K, .gallery); tlSelect(1, [K.appendingPathComponent("b.txt")]); app.focusPane(1); await settle(0.4)
        arrow(125); await settle(0.3)
        check("画廊视图：↓ 移到下一项", selName() == "c.txt", selName())
        arrow(126); await settle(0.3)
        check("画廊视图：↑ 回到上一项", selName() == "b.txt", selName())
        await go(1, K, .icon); tlSelect(1, [K.appendingPathComponent("b.txt")]); app.focusPane(1); await settle(0.5)
        let iconStart = selName()
        arrow(125); await settle(0.3)
        let down = selName()
        arrow(126); await settle(0.3)
        check("图标视图：↓ 换到下一行、↑ 回来", iconStart == "b.txt" && down != "b.txt" && !down.isEmpty && selName() == "b.txt", "\(iconStart) → \(down) → \(selName())（每行 \(app.controllers[1].iconColumns) 个）")

        // ===== 4. 分栏视图：层级很深时每栏不压缩、横向滚动、自动滚到最新一栏 =====
        var deep = T; var levels: [URL] = []
        for i in 1...7 { deep = deep.appendingPathComponent("层\(i)"); levels.append(deep) }
        try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let png = deep.appendingPathComponent("预览图.png")
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 400, height: 200).fill()
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
        }
        await go(1, T, .column)
        let tT = app.panes[1].tab
        for (k, u) in levels.enumerated() {
            app.controllers[1].columnSelect(u, at: k)
            await waitUntil(3) { tT.columnLoader?.lists[u.path] != nil }
        }
        await settle(1.0)
        let sv = columnScrollView(1)
        let docW = sv?.documentView?.frame.width ?? 0, visW = sv?.contentSize.width ?? 0
        let maxX = sv?.contentView.bounds.maxX ?? 0
        let colsN = 1 + levels.count
        check("分栏视图：8 栏时内容宽度 ≥ 8 × 231，每栏不被压缩", docW >= CGFloat(colsN) * 231, "内容 \(Int(docW))，可见 \(Int(visW))")
        check("分栏视图：有横向滚动条，并自动滚到最新一栏", (sv?.hasHorizontalScroller ?? false) && docW > visW && maxX >= CGFloat(colsN) * 231 - 2, "可见右边缘 \(Int(maxX))，最新一栏右边缘 \(colsN * 231)，内容 \(Int(docW))")
        let colWidths = RightClick.markers.allObjects.filter { $0.window === win && $0.tab === tT && $0.bg && !$0.isHiddenOrHasHiddenAncestor }.map { Int($0.frame.width.rounded()) }
        check("分栏视图：每一栏都是 230 点宽", colWidths.filter { $0 == 230 }.count >= colsN, "\(colWidths)")
        shot("ui-column-deep")

        // ===== 5. 分栏视图预览栏：居中、按比例缩放 =====
        ColumnPreview.lastLayout = nil
        app.controllers[1].columnSelect(png, at: levels.count); await settle(1.5)
        if let L = ColumnPreview.lastLayout {
            let dx = abs(L.image.midX - L.column.midX), top = L.image.minY - L.column.minY
            check("分栏预览：图像在预览栏里水平居中、不贴左上角", dx < 2 && top > 20 && L.image.width >= 200, String(format: "偏差 %.1f，上边距 %.0f，图像 %.0f×%.0f，栏 %.0f×%.0f", dx, top, L.image.width, L.image.height, L.column.width, L.column.height))
        } else { check("分栏预览：图像在预览栏里居中", false, "没有显示预览栏") }
        shot("ui-column-preview")

        // ===== 3. 路径栏右键：拷贝路径 =====
        await go(0, S, .list); app.focusPane(0); await settle(0.4)
        if let seg = markers(0, seg: true).first(where: { $0.url?.lastPathComponent == "v061" }), let u = seg.url {
            let titles = await rightClickMenu(mid(seg), choose: "拷贝路径")
            await settle(0.2)
            let s = NSPasteboard.general.string(forType: .string) ?? ""
            check("路径栏右键：有「拷贝路径」「在新标签页中打开」「在访达中显示」", ["拷贝路径", "在新标签页中打开", "在访达中显示"].allSatisfy(titles.contains), titles.joined(separator: " | "))
            check("路径栏右键：拷贝路径 = 到这一段为止的 POSIX 路径", s == u.path, s)
            let nTabs = app.panes[0].tabs.count
            _ = await rightClickMenu(mid(seg), choose: "在新标签页中打开"); await settle(0.6)
            check("路径栏右键：在新标签页中打开", app.panes[0].tabs.count == nTabs + 1 && app.panes[0].tab.path.lastPathComponent == "v061", "\(app.panes[0].tabs.count) 个标签页，\(app.panes[0].tab.path.lastPathComponent)")
            if app.panes[0].tabs.count > nTabs { app.closeTab(pane: 0); await settle(0.4) }
        } else { check("路径栏右键：找到路径栏的「v061」一段", false, "\(markers(0, seg: true).compactMap { $0.url?.lastPathComponent })") }

        // ===== 6. 最近访问：未装载磁盘上的记录不显示，记录保留；可以移除 =====
        let ghost = URL(fileURLWithPath: "/Volumes/FBTestNotMounted-v061/影片")
        app.visited(S)
        app.recents.insert(ghost, at: 0); app.objectWillChange.send(); await settle(0.3)
        check("最近访问：未装载磁盘上的记录不显示，但记录保留", !app.visibleRecents.contains(ghost) && app.recents.contains(ghost) && app.visibleRecents.contains { $0.path == S.path }, "显示 \(app.visibleRecents.count) / 记录 \(app.recents.count)")
        app.removeRecent(S)
        let stored = UserDefaults.standard.stringArray(forKey: "recents") ?? []
        check("最近访问：右键「从最近访问中移除」删除记录并保存", !app.recents.contains { $0.path == S.path } && !stored.contains(S.path))
        app.recents.removeAll { $0 == ghost }

        // ===== 7. 文件夹的快速查看 =====
        await go(0, D, .list); await moveMouse(to: center(0)); app.focusPane(0)
        await tableSelect(0, ["空文件夹"]); await settle(0.3)
        let peek = FolderPeek.shared
        app.sizeReq = nil
        press(" ", 49)
        await waitUntil(3) { peek.isVisible && peek.count.stringValue == "0 个项目" }
        check("文件夹快速查看：空文件夹按空格显示（名称、0 个项目、修改时间）", peek.isVisible && peek.name.stringValue == "空文件夹" && peek.count.stringValue == "0 个项目" && peek.date.stringValue.hasPrefix("修改时间"), "\(peek.isVisible) \(peek.name.stringValue) \(peek.count.stringValue)")
        check("文件夹快速查看：不自动计算大小", app.sizeReq == nil)
        await tableSelect(0, ["下载"])
        await waitUntil(3) { peek.count.stringValue == "11 个项目" }
        check("文件夹快速查看：换选中的文件夹时跟着更新（11 个项目）", peek.isVisible && peek.name.stringValue == "下载" && peek.count.stringValue == "11 个项目", peek.count.stringValue)
        peek.button.performClick(nil); await settle(0.4)
        check("文件夹快速查看：点「空间分析…」才开始计算这个文件夹", app.sizeReq?.url.lastPathComponent == "下载" && !peek.isVisible)
        app.sizeReq = nil; await settle(0.6)
        app.focusPane(0); await settle(0.2)
        press(" ", 49); await waitUntil(2) { peek.isVisible }
        press("\u{1b}", 53); await settle(0.3)
        check("文件夹快速查看：Esc 关闭", !peek.isVisible)
        peek.close()

        // 收尾
        DragMods.override = []
        for i in 0..<2 { await go(i, entry[i].0, entry[i].1) }
        for u in trashed { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: D)
    }
}
