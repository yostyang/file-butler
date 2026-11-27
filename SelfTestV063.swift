import AppKit
import Foundation
import CoreServices

/// v0.6.3 / v0.7 自测：目录监视能在约 1 秒内看到外部对当前文件夹的改动（原地写入、原子保存、新建、删除），
/// 分栏视图打开的子文件夹和双栏里同一份目录也会更新。只在 /tmp/fb-test 里操作。
extension SelfTest {
    static func v063(root: URL, report: (String, Bool, String) -> Void) {
        func check(_ n: String, _ ok: Bool, _ note: String = "") { report(n, ok, note) }
        let fm = FileManager.default
        func waitUntil(_ timeout: TimeInterval, _ pred: () -> Bool) -> TimeInterval? {
            let start = Date()
            let end = start.addingTimeInterval(timeout)
            while Date() < end {
                if pred() { return Date().timeIntervalSince(start) }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            return pred() ? Date().timeIntervalSince(start) : nil
        }
        func item(_ tab: TabModel, _ name: String) -> FileItem? { tab.items.first { $0.name == name } }
        func sizeOf(_ tab: TabModel, _ name: String) -> Int64? { item(tab, name)?.size }

        // 纯函数：哪些事件该触发刷新（/tmp 与 /private/tmp 视为同一路径；未打开的子目录忽略）
        let dir = "/tmp/fb-watch-rel"
        check("目录监视：当前文件夹里的文件改动是相关事件",
              folderWatchIsRelevant(eventPath: dir + "/note.txt", flags: 0, roots: [dir]))
        check("目录监视：/tmp 与 /private/tmp 视为同一个文件夹",
              folderWatchIsRelevant(eventPath: "/private/tmp/fb-watch-rel/note.txt", flags: 0, roots: ["/tmp/fb-watch-rel"]))
        check("目录监视：未打开的子文件夹里的改动不触发重读",
              !folderWatchIsRelevant(eventPath: dir + "/sub/inner.txt", flags: 0, roots: [dir]))
        check("目录监视：分栏视图已打开的子文件夹里的改动是相关事件",
              folderWatchIsRelevant(eventPath: dir + "/sub/inner.txt", flags: 0, roots: [dir, dir + "/sub"]))
        check("目录监视：必须整树扫描的标志始终触发刷新",
              folderWatchIsRelevant(eventPath: dir + "/sub/deep/x", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), roots: [dir]))

        let W = root.appendingPathComponent("watch")
        try? fm.removeItem(at: W)
        do {
            try fm.createDirectory(at: W.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try "v1".write(to: W.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
            try "inner1".write(to: W.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)
        } catch { check("目录监视：准备测试文件夹", false, error.localizedDescription); return }

        // 资源值缓存：外部原地改写后，makeItem 必须读到新的大小（以前会命中旧缓存）
        let note = W.appendingPathComponent("note.txt")
        let beforeCache = makeItem(note)
        do {
            let h = try FileHandle(forWritingTo: note)
            try h.seekToEnd()
            h.write("CACHE".data(using: .utf8)!)
            try h.close()
        } catch { check("目录监视：缓存测试写入", false, error.localizedDescription) }
        let afterCache = makeItem(note)
        check("读取属性：原地改写后立刻读到新的大小（不走旧缓存）",
              afterCache.size > beforeCache.size && afterCache.size == (try? FileManager.default.attributesOfItem(atPath: note.path)[.size] as? NSNumber)?.int64Value,
              "前 \(beforeCache.size) → 后 \(afterCache.size)")
        try? "v1".write(to: note, atomically: true, encoding: .utf8)

        let app = AppState()
        let tab = app.panes[0].tab
        let tab2 = app.panes[1].tab
        tab.viewMode = .list
        tab.navigate(W)
        guard let tInit = waitUntil(2.0, { item(tab, "note.txt") != nil }) else {
            check("目录监视：打开测试文件夹后列出 note.txt", false, "2 秒内没有出现")
            return
        }
        check("目录监视：打开测试文件夹后列出 note.txt", true, String(format: "%.2fs", tInit))

        // 1) 原地写入（DispatchSource 对这种情况不发事件；这是本次修复的主路径）
        let size1 = sizeOf(tab, "note.txt") ?? 0
        do {
            let h = try FileHandle(forWritingTo: note)
            try h.seekToEnd()
            h.write("APPENDED".data(using: .utf8)!)
            try h.close()
        } catch { check("目录监视：原地写入", false, error.localizedDescription) }
        if let dt = waitUntil(1.0, { (sizeOf(tab, "note.txt") ?? 0) > size1 }) {
            let now = sizeOf(tab, "note.txt") ?? 0
            check("目录监视：原地改文件后 1 秒内更新大小 / 修改时间", true, String(format: "%.2fs，%d → %d 字节", dt, size1, now))
        } else {
            check("目录监视：原地改文件后 1 秒内更新大小 / 修改时间", false, "仍是 \(sizeOf(tab, "note.txt") ?? -1) 字节")
        }

        // 2) 原子保存（写临时文件再改名，编辑器常用）
        let atomicBody = "atomic-save-content-xxxxxxxx"
        try? atomicBody.write(to: note, atomically: true, encoding: .utf8)
        let atomicSize = Int64(atomicBody.data(using: .utf8)!.count)
        if let dt = waitUntil(1.0, { sizeOf(tab, "note.txt") == atomicSize }) {
            check("目录监视：原子保存后 1 秒内更新大小", true, String(format: "%.2fs，%d 字节", dt, atomicSize))
        } else {
            check("目录监视：原子保存后 1 秒内更新大小", false, "现在 \(sizeOf(tab, "note.txt") ?? -1) 字节，期望 \(atomicSize)")
        }

        // 3) 新建
        let created = W.appendingPathComponent("created.txt")
        try? "new-file".write(to: created, atomically: true, encoding: .utf8)
        if let dt = waitUntil(1.0, { item(tab, "created.txt") != nil }) {
            check("目录监视：新建文件后 1 秒内出现在列表里", true, String(format: "%.2fs", dt))
        } else {
            check("目录监视：新建文件后 1 秒内出现在列表里", false)
        }

        // 4) 删除
        try? fm.removeItem(at: created)
        if let dt = waitUntil(1.0, { item(tab, "created.txt") == nil }) {
            check("目录监视：删除文件后 1 秒内从列表里消失", true, String(format: "%.2fs", dt))
        } else {
            check("目录监视：删除文件后 1 秒内从列表里消失", false)
        }

        // 列表 / 图标 / 画廊共用同一份已更新的 items；预览栏读 selectedItems 的大小和修改时间
        tab.selection = [note]
        let previewSize = tab.selectedItems.first?.size
        check("预览 / 选中项：读到的是刷新后的大小", previewSize == atomicSize, "选中项 \(previewSize ?? -1) 字节，文件 \(atomicSize) 字节")
        var viewOK = true
        for m in [ViewMode.list, .icon, .gallery] {
            tab.viewMode = m
            if sizeOf(tab, "note.txt") != atomicSize { viewOK = false }
        }
        check("列表 / 图标 / 画廊视图共用刷新后的目录数据", viewOK)

        // 双栏：另一栏打开同一个文件夹，也应在 1 秒内看到改动
        tab2.viewMode = .list
        tab2.navigate(W)
        guard waitUntil(2.0, { item(tab2, "note.txt") != nil }) != nil else {
            check("目录监视：双栏另一栏打开同一文件夹", false); return
        }
        do {
            let h = try FileHandle(forWritingTo: note)
            try h.seekToEnd()
            h.write("PANE2".data(using: .utf8)!)
            try h.close()
        } catch { check("目录监视：双栏写入", false, error.localizedDescription) }
        let expect2 = (try? FileManager.default.attributesOfItem(atPath: note.path)[.size] as? NSNumber)?.int64Value ?? -1
        let dtA = waitUntil(1.0, { sizeOf(tab, "note.txt") == expect2 })
        let dtB = waitUntil(1.0, { sizeOf(tab2, "note.txt") == expect2 })
        check("双栏：两栏都在 1 秒内更新同一文件的大小", dtA != nil && dtB != nil,
              String(format: "左栏 %@，右栏 %@，期望 %d", dtA.map { String(format: "%.2fs", $0) } ?? "超时", dtB.map { String(format: "%.2fs", $0) } ?? "超时", expect2))

        // 分栏视图：只监视第一栏时，子栏里的原地改写不会出现；现在应对 columnChain 里的文件夹生效
        let sub = W.appendingPathComponent("sub")
        let inner = sub.appendingPathComponent("inner.txt")
        let loader = ColumnLoader()
        tab.viewMode = .column
        tab.columnChain = [sub]
        tab.columnLoader = loader
        tab.reload()
        guard waitUntil(2.0, { (loader.lists[sub.path] ?? []).contains { $0.name == "inner.txt" } }) != nil else {
            check("分栏视图：右侧栏列出 inner.txt", false); return
        }
        let innerBefore = loader.lists[sub.path]?.first { $0.name == "inner.txt" }?.size ?? 0
        do {
            let h = try FileHandle(forWritingTo: inner)
            try h.seekToEnd()
            h.write("COL".data(using: .utf8)!)
            try h.close()
        } catch { check("分栏视图：写入子栏文件", false, error.localizedDescription) }
        if let dt = waitUntil(1.0, { (loader.lists[sub.path]?.first { $0.name == "inner.txt" }?.size ?? 0) > innerBefore }) {
            let now = loader.lists[sub.path]?.first { $0.name == "inner.txt" }?.size ?? 0
            check("分栏视图：已打开的子文件夹里原地改文件后 1 秒内更新", true, String(format: "%.2fs，%d → %d 字节", dt, innerBefore, now))
        } else {
            let now = loader.lists[sub.path]?.first { $0.name == "inner.txt" }?.size ?? -1
            check("分栏视图：已打开的子文件夹里原地改文件后 1 秒内更新", false, "仍是 \(now) 字节")
        }

        // 未打开的更深子目录：不应让当前列表无故重读（用 version 观察）
        let deep = W.appendingPathComponent("noise/deep")
        try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        _ = waitUntil(1.0, { item(tab, "noise") != nil })   // 新建 noise 文件夹是当前目录的直接子项，会刷新一次
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))  // 等这次刷新走完
        let ver = tab.version
        try? "zzz".write(to: deep.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        check("目录监视：未打开的子目录里改文件不会重读当前列表", tab.version == ver, "version \(ver) → \(tab.version)")

        tab.columnLoader = nil
        tab.columnChain = []
        tab.viewMode = .list
        try? fm.removeItem(at: W)

        // ===== v0.7：置顶文件夹 + 保存布局 =====
        let V7 = root.appendingPathComponent("v07")
        let pA = V7.appendingPathComponent("深层/项目A"), pB = V7.appendingPathComponent("素材盘/Seed"), pC = V7.appendingPathComponent("归档")
        try? fm.removeItem(at: V7)
        for d in [pA, pB, pC] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }

        app.pinnedFolders = []; Settings.pinnedFolders = []
        app.pinFolder(pA)
        app.pinFolder(pB, alias: "剪辑素材")
        app.pinFolder(pA)   // 重复置顶不产生重复项
        check("置顶文件夹：加入与按路径去重", app.pinnedFolders.count == 2 && app.isPinned(pA) && app.isPinned(pB), "\(app.pinnedFolders.map { $0.displayName })")
        check("置顶文件夹：支持自定义显示名", app.pinnedFolders[0].displayName == "项目A" && app.pinnedFolders[1].displayName == "剪辑素材")
        app.movePinnedFolder(app.pinnedFolders[1], by: -1)
        check("置顶文件夹：上移 / 下移调整顺序并持久化", app.pinnedFolders.map { $0.displayName } == ["剪辑素材", "项目A"] && Settings.pinnedFolders.map { $0.displayName } == ["剪辑素材", "项目A"])
        app.renamePinnedFolder(app.pinnedFolders[0], to: "Seed 素材")
        check("置顶文件夹：重命名显示名", app.pinnedFolders[0].displayName == "Seed 素材")
        // 未装载外置盘上的置顶文件夹自动隐藏（只比较路径字符串，不读磁盘），记录保留
        let unmountedPin = PinnedFolder(path: "/Volumes/UnmountedDrive-v07/Raw", alias: "未挂载盘")
        app.pinnedFolders.append(unmountedPin)
        check("置顶文件夹：未装载外置盘上的记录自动隐藏但保留", app.pinnedFolders.count == 3 && app.visiblePinnedFolders.count == 2 && !app.visiblePinnedFolders.contains(where: { $0.path == unmountedPin.path }))
        // 命令面板能按原名和自定义显示名搜到置顶文件夹
        let snap = PaletteEngine.snapshot(app)
        let byAlias = PaletteEngine.rank("Seed 素材", commands: [], files: snap, app: app)
        check("置顶文件夹：命令面板可按自定义显示名命中", byAlias.first?.title == "Seed 素材" && byAlias.first?.kind == .folder, byAlias.map { $0.title }.joined(separator: "|"))
        app.unpinFolder(pA); app.unpinFolder(pB); app.unpinFolder(unmountedPin.url)
        check("置顶文件夹：取消置顶", app.pinnedFolders.isEmpty && Settings.pinnedFolders.isEmpty)

        // 保存布局：记录单/双栏、各栏多标签页路径、显示方式与排序，一键恢复
        app.layouts = []; Settings.savedLayouts = []
        app.dual = true
        app.panes[0].tabs = [TabModel(path: pA, app: app, mode: .icon), TabModel(path: pC, app: app, mode: .column)]
        app.panes[0].current = 1
        app.panes[0].tabs[1].setSort(.size, asc: false)
        app.panes[1].tabs = [TabModel(path: pB, app: app, mode: .list)]
        app.panes[1].current = 0
        app.active = 1
        let layout = app.saveCurrentLayout(name: "剪辑")
        check("保存布局：记录双栏、多标签页、显示方式与排序并持久化",
              app.layouts.count == 1 && Settings.savedLayouts.count == 1 && layout.dual && layout.panes[0].tabs.count == 2 && layout.panes[0].current == 1 && layout.panes[1].tabs[0].path == pB.standardizedFileURL.path,
              layout.summary)
        // 切走：改成单栏、不同文件夹、不同视图
        app.dual = false
        app.panes[0].tabs = [TabModel(path: V7, app: app, mode: .gallery)]
        app.panes[0].current = 0
        // 一键恢复布局
        app.applyLayout(layout)
        check("保存布局：一键恢复双栏、各栏标签页、激活栏、显示方式与排序",
              app.dual && app.active == 1 && app.panes[0].tabs.count == 2 && app.panes[0].current == 1 &&
              samePath(app.panes[0].tab.path, pC) && app.panes[0].tab.viewMode == .column &&
              app.panes[0].tab.sortKey == .size && app.panes[0].tab.asc == false &&
              samePath(app.panes[1].tab.path, pB) && app.panes[1].tab.viewMode == .list,
              "dual=\(app.dual) p0=\(app.panes[0].tab.path.lastPathComponent)(\(app.panes[0].tab.viewMode.rawValue)) p1=\(app.panes[1].tab.path.lastPathComponent)")
        // 更新、重命名与缺失路径容错
        app.panes[1].tab.navigate(pA)
        app.updateLayout(layout)
        app.renameLayout(layout, to: "剪辑工作区")
        check("保存布局：用当前窗口状态更新与重命名",
              app.layouts.first?.name == "剪辑工作区" && app.layouts.first?.panes[1].tabs.first?.path == pA.standardizedFileURL.path)
        var broken = app.layouts[0]
        broken.panes[0].tabs.append(TabSnapshot(path: "/Volumes/Unmounted-v07/Missing", viewMode: "list", sortKey: "name", sortAsc: true))
        app.alert = nil
        app.applyLayout(broken)
        check("保存布局：含未装载或不存在路径时打开其余可用标签页并提示",
              app.panes[0].tabs.count == 2 && app.alert?.title == "部分布局路径未打开")
        app.alert = nil
        app.removeLayout(app.layouts[0])
        check("保存布局：删除布局", app.layouts.isEmpty && Settings.savedLayouts.isEmpty)
        try? fm.removeItem(at: V7)

        // 排序与分组性能回归：2000 个项目切换修改日期/大小/种类排序及按日期分组应在数毫秒内完成
        let now = Date()
        let kinds = ["文稿", "PNG 图像", "文件夹", "PDF 文稿"]
        var sample: [FileItem] = []
        sample.reserveCapacity(2000)
        for i in 0..<2000 {
            let u = URL(fileURLWithPath: "/tmp/fb-sort-\(i).txt")
            let nm = "文件_\(i % 97)_\(i).txt"
            let sz = Int64((i * 1049) % 10_000_000)
            let dt = now.addingTimeInterval(-Double((i * 3600) % (400 * 86400)))
            sample.append(FileItem(url: u, name: nm, isDir: i % 20 == 0, isPackage: false, size: sz,
                                   modified: dt, created: now, kind: kinds[i % 4], hidden: false, tags: []))
        }
        let tSort0 = CFAbsoluteTimeGetCurrent()
        _ = sortItems(sample, key: .date, asc: false)
        _ = sortItems(sample, key: .size, asc: false)
        _ = groupItems(sample, by: .date)
        _ = groupItems(sample, by: .size)
        let sortGroupMs = (CFAbsoluteTimeGetCurrent() - tSort0) * 1000
        check("性能：2000 项按日期/大小排序 + 按日期/大小分组 < 50ms", sortGroupMs < 50, String(format: "%.1fms", sortGroupMs))
    }
}
