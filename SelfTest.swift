import AppKit
import Foundation

/// `FileButler --selftest`: exercises the file operations in /tmp/fb-test only, prints PASS/FAIL, exits.
enum SelfTest {
    static func run() -> Int32 {
        // 自测会创建 AppState，它会记住标签页等设置；结束时把用户的设置原样还原
        let id = Bundle.main.bundleIdentifier ?? "com.yost.filebutler"
        let saved = UserDefaults.standard.persistentDomain(forName: id)
        defer {
            if let d = saved { UserDefaults.standard.setPersistentDomain(d, forName: id) } else { UserDefaults.standard.removePersistentDomain(forName: id) }
            UserDefaults.standard.synchronize()
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/fb-test")
        var pass = 0, fail = 0
        var trashLeftovers: [URL] = []
        func check(_ name: String, _ ok: Bool, _ note: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            print((ok ? "PASS  " : "FAIL  ") + name + (note.isEmpty ? "" : "  — " + note))
        }
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        try? fm.removeItem(at: root)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        do {
            try fm.createDirectory(at: a.appendingPathComponent("dir1"), withIntermediateDirectories: true)
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            try "hello".write(to: a.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
            try "inner".write(to: a.appendingPathComponent("dir1/inner.txt"), atomically: true, encoding: .utf8)
        } catch { print("SETUP FAILED: \(error)"); return 2 }
        let f1 = a.appendingPathComponent("file1.txt")

        // new folder + undo
        do {
            let nf = try FileOps.newFolder(in: a)
            check("新建文件夹", exists(nf) && nf.lastPathComponent == "未命名文件夹")
            let nf2 = try FileOps.newFolder(in: a)
            check("新建第二个文件夹自动编号", nf2.lastPathComponent == "未命名文件夹 2")
            trashLeftovers += try FileOps.undo(.created([nf2]))
            trashLeftovers += try FileOps.undo(.created([nf]))
            check("撤销新建文件夹（移到废纸篓）", !exists(nf) && !exists(nf2) && trashLeftovers.allSatisfy { exists($0) })
        } catch { check("新建文件夹", false, error.localizedDescription) }

        // rename + undo + validation
        do {
            let r = try FileOps.rename(f1, to: "renamed.txt")
            check("重命名", exists(r) && !exists(f1) && text(r) == "hello")
            try FileOps.undo(.rename(f1, r))
            check("撤销重命名", exists(f1) && !exists(r))
            check("拒绝含 / 的名称", (try? FileOps.rename(f1, to: "a/b")) == nil)
            check("拒绝与已有项目重名", (try? FileOps.rename(f1, to: "dir1")) == nil && exists(f1))
        } catch { check("重命名", false, error.localizedDescription) }

        // copy + undo
        var r = FileOps.transfer([f1], to: b, mode: .copy)
        let c1 = b.appendingPathComponent("file1.txt")
        check("拷贝到另一文件夹", r.copied == [c1] && exists(c1) && exists(f1) && text(c1) == "hello", r.errs.joined())
        r = FileOps.transfer([f1], to: b, mode: .copy)
        check("拷贝到别处遇到同名：保留两者 → 「file1 2.txt」（访达）", r.copied.first?.lastPathComponent == "file1 2.txt", r.copied.first?.lastPathComponent ?? "")
        if let more = try? FileOps.undo(.created(r.copied)) { trashLeftovers += more }
        check("撤销拷贝", !exists(b.appendingPathComponent("file1 2.txt")))
        // 同名冲突：替换 / 停止 / 跳过 / 全部应用
        try? "old".write(to: c1, atomically: true, encoding: .utf8)
        r = FileOps.transfer([f1], to: b, mode: .copy, resolve: { _, _ in (.stop, false) })
        check("同名冲突：停止 → 不改动", r.cancelled && r.copied.isEmpty && text(c1) == "old")
        r = FileOps.transfer([f1], to: b, mode: .copy, resolve: { _, _ in (.replace, false) })
        check("同名冲突：替换 → 新内容，旧项目进废纸篓（可撤销）", text(c1) == "hello" && r.replaced.count == 1 && exists(r.replaced[0].1))
        if let more = try? FileOps.undo(.group([.trashed(r.replaced), .created(r.copied)])) { trashLeftovers += more }
        check("撤销替换 → 旧内容回来", text(c1) == "old", text(c1))
        let g1 = a.appendingPathComponent("g1.txt"), g2 = a.appendingPathComponent("g2.txt")
        try? "1".write(to: g1, atomically: true, encoding: .utf8); try? "2".write(to: g2, atomically: true, encoding: .utf8)
        _ = FileOps.transfer([g1, g2], to: b, mode: .copy)
        var asked = 0
        r = FileOps.transfer([g1, g2], to: b, mode: .copy, resolve: { _, _ in asked += 1; return (.skip, true) })
        check("同名冲突：跳过 + 全部应用 → 只问一次", asked == 1 && r.copied.isEmpty, "asked=\(asked)")
        try? fm.removeItem(at: g1); try? fm.removeItem(at: g2)
        // 拖放规则（访达）
        let other = root.appendingPathComponent("drop"); try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        DragMods.override = []; check("拖放：同一卷默认移动", planDrop([f1], to: other) == .move)
        DragMods.override = .option; check("拖放：⌥ 拷贝", planDrop([f1], to: other) == .copy)
        DragMods.override = .command; check("拖放：⌘ 移动", planDrop([f1], to: other) == .move)
        DragMods.override = [.option, .command]; check("拖放：⌥⌘ 替身", planDrop([f1], to: other) == .alias)
        DragMods.override = []; check("拖放：拖回原文件夹无效", planDrop([f1], to: a) == .none)
        check("拖放：拖进自身无效", planDrop([a], to: a.appendingPathComponent("dir1")) == .none)
        check("拖放：⌥ 拖回原文件夹 = 拷贝（副本）", { DragMods.override = .option; defer { DragMods.override = [] }; return planDrop([f1], to: a) == .copy }())
        if let al = try? FileOps.makeAlias(f1, in: other) {
            check("⌥⌘ 拖放制作替身：同名、可解析", al.lastPathComponent == "file1.txt" && (try? URL(resolvingAliasFileAt: al))?.standardizedFileURL.path == f1.standardizedFileURL.path)
        } else { check("⌥⌘ 拖放制作替身", false) }
        DragMods.override = nil
        // 可取消
        let big = root.appendingPathComponent("big"); try? fm.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<200 { try? "x".write(to: big.appendingPathComponent("f\(i).txt"), atomically: false, encoding: .utf8) }
        let pr = OpProgress(); pr.cancel()
        r = FileOps.transfer(((try? fm.contentsOfDirectory(at: big, includingPropertiesForKeys: nil)) ?? []), to: other, mode: .copy, progress: pr)
        check("取消操作：立即停止", r.cancelled && r.copied.isEmpty)

        // duplicate (copy into same folder)
        r = FileOps.transfer([f1], to: a, mode: .copy)
        check("制作副本", r.copied.first?.lastPathComponent == "file1 副本.txt" && exists(a.appendingPathComponent("file1 副本.txt")))
        if let more = try? FileOps.undo(.created(r.copied)) { trashLeftovers += more }

        // move + undo
        let d1 = a.appendingPathComponent("dir1")
        r = FileOps.transfer([d1], to: b, mode: .move)
        let d1b = b.appendingPathComponent("dir1")
        check("移动文件夹", !exists(d1) && exists(d1b.appendingPathComponent("inner.txt")), r.errs.joined())
        do { try FileOps.undo(.moved(r.moved)); check("撤销移动", exists(d1.appendingPathComponent("inner.txt")) && !exists(d1b)) }
        catch { check("撤销移动", false, error.localizedDescription) }
        let c = root.appendingPathComponent("c"); try? fm.createDirectory(at: c, withIntermediateDirectories: true)
        r = FileOps.transfer([f1], to: c, mode: .auto)
        check("同一磁盘拖放默认为移动", r.moved.count == 1 && !exists(f1), r.errs.joined())
        _ = try? FileOps.undo(.moved(r.moved))
        r = FileOps.transfer([a], to: d1, mode: .move)
        check("禁止把文件夹放进自身", !r.errs.isEmpty && exists(a))
        try? "x".write(to: b.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        r = FileOps.transfer([f1], to: b, mode: .move, resolve: { _, _ in (.stop, false) })
        check("移动遇到同名：停止 → 不覆盖", r.moved.isEmpty && exists(f1) && text(b.appendingPathComponent("file1.txt")) == "x")

        // trash + undo restore
        let t = FileOps.trash([f1])
        check("移到废纸篓", !exists(f1) && t.done.count == 1 && exists(t.done[0].1), t.done.first?.1.path ?? t.errs.joined())
        do { try FileOps.undo(.trashed(t.done)); check("撤销废纸篓（恢复原位）", exists(f1) && text(f1) == "hello") }
        catch { check("撤销废纸篓（恢复原位）", false, error.localizedDescription) }

        // tags
        do {
            try FileOps.setTags(f1, ["红色", "FB测试"])
            let got = FileOps.readTags(f1)
            check("写入并读取标签", Set(got) == ["红色", "FB测试"], got.joined(separator: ","))
            check("列表项读取标签", Set(makeItem(f1).tags) == ["红色", "FB测试"])
            try FileOps.setTags(f1, [])
            check("清除标签", FileOps.readTags(f1).isEmpty)
        } catch { check("写入标签", false, error.localizedDescription) }

        // zip
        do {
            let z = try FileOps.zip([d1])
            check("压缩单个文件夹（ditto）", z.lastPathComponent == "dir1.zip" && ((try? fm.attributesOfItem(atPath: z.path)[.size] as? Int) ?? 0) > 0)
            let z2 = try FileOps.zip([d1])
            check("重复压缩自动编号", z2.lastPathComponent == "dir1 2.zip", z2.lastPathComponent)
            let z3 = try FileOps.zip([f1, d1])
            check("压缩多个项目（归档.zip）", z3.lastPathComponent == "归档.zip" && exists(z3))
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-l", z3.path]
            let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
            let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            check("压缩包内容正确", listing.contains("file1.txt") && listing.contains("dir1/inner.txt"))
            check("跨文件夹压缩会被拒绝", (try? FileOps.zip([f1, b.appendingPathComponent("file1.txt")])) == nil)
        } catch { check("压缩", false, error.localizedDescription) }

        // 访达同款：新建文件夹命名序列、用所选项目新建文件夹、制作替身
        do {
            let n1 = try FileOps.newFolder(in: b), n2 = try FileOps.newFolder(in: b), n3 = try FileOps.newFolder(in: b)
            check("新建文件夹命名序列（未命名文件夹 / 2 / 3）", [n1, n2, n3].map { $0.lastPathComponent } == ["未命名文件夹", "未命名文件夹 2", "未命名文件夹 3"])
            let x = b.appendingPathComponent("x.txt"), y = b.appendingPathComponent("y.txt")
            try "x".write(to: x, atomically: true, encoding: .utf8); try "y".write(to: y, atomically: true, encoding: .utf8)
            let r = try FileOps.newFolderWithItems([x, y])
            check("用所选项目新建文件夹", r.folder.lastPathComponent == "新建文件夹包含项目" && exists(r.folder.appendingPathComponent("x.txt")) && exists(r.folder.appendingPathComponent("y.txt")) && !exists(x))
            trashLeftovers += try FileOps.undo(.group([.created([r.folder]), .moved(r.moved)]))
            check("撤销用所选项目新建文件夹", exists(x) && exists(y) && !exists(r.folder))
            let al = try FileOps.makeAlias(x)
            var stale = false
            let target = try? URL(resolvingAliasFileAt: al, options: [])
            _ = stale; stale = false
            check("制作替身（X 的替身，可解析回原文件）", al.lastPathComponent == "x.txt 的替身" && target?.standardizedFileURL.path == x.standardizedFileURL.path, target?.path ?? "无法解析")
            check("就地重命名选中范围（不含扩展名）", baseNameRange("报告.final.pdf", isDir: false).length == ("报告.final" as NSString).length && baseNameRange("未命名文件夹", isDir: true).length == 6)
        } catch { check("访达同款新建文件夹", false, error.localizedDescription) }

        // 空文件夹的背景右键菜单（访达顺序）
        do {
            let empty = b.appendingPathComponent("空的"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let app = AppState(); let tab = app.panes[0].tab
            tab.navigate(empty)
            let t = specTitles(contextSpec(app: app, tab: tab, pane: 0, urls: [], bgDir: empty))
            let t0 = t.map { $0.contains("粘贴") ? "粘贴项目" : $0 }
            let want = ["新建文件夹", "粘贴项目", "—", "显示简介", "—", "显示▸", "使用群组", "排序方式▸", "查看显示选项", "—", "文件管家▸"]
            let f1 = empty.appendingPathComponent("sub"); try? FileManager.default.createDirectory(at: f1, withIntermediateDirectories: true)
            tab.viewMode = .column; tab.columnChain = [f1]; tab.selection = []
            let pt1 = tab.pathTarget, ti = tab.title
            tab.selection = [f1]
            check("路径栏跟随分栏选中项", pt1.lastPathComponent == "sub" && ti == "sub" && tab.pathTarget.lastPathComponent == "sub")
            tab.columnChain = []; tab.selection = []; tab.viewMode = .list
            check("空文件夹背景菜单与访达一致", t0 == want, t.joined(separator: " "))
        } catch { check("背景菜单", false, error.localizedDescription) }

        // 快速操作：向左旋转图片（原文件进废纸篓，可找回）
        do {
            let img = b.appendingPathComponent("旋转.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: img)
            _ = try QuickActions.rotateImageLeft(img)
            if let t = QuickActions.lastTrashed { trashLeftovers.append(t) }
            let r2 = NSBitmapImageRep(data: try Data(contentsOf: img))
            check("向左旋转图片（40×20 → 20×40）", r2?.pixelsWide == 20 && r2?.pixelsHigh == 40, "\(r2?.pixelsWide ?? 0)×\(r2?.pixelsHigh ?? 0)")
            check("访达式日期格式", finderDate(Date(timeIntervalSince1970: 1760597820)).hasPrefix("2025年10月16日 星期四"), finderDate(Date(timeIntervalSince1970: 1760597820)))
            check("持续时间格式 02:24", finderDuration(144) == "02:24")
        } catch { check("向左旋转图片", false, error.localizedDescription) }

        // grouping and filtering logic
        let items = ((try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: listKeys)) ?? []).map(makeItem)
        let gk = groupItems(items, by: .kind)
        check("按种类分组", gk.first?.0 == "文件夹" && gk.reduce(0) { $0 + $1.1.count } == items.count)
        check("按大小分组", groupItems(items, by: .size).reduce(0) { $0 + $1.1.count } == items.count)
        check("按日期分组", groupItems(items, by: .date).first?.0 == "今天")
        let sorted = sortItems(items, key: .name, asc: true).map { $0.name }
        check("按名称排序", sorted == sorted.sorted { $0.localizedStandardCompare($1) == .orderedAscending } && sortItems(items, key: .name, asc: false).map { $0.name } == sorted.reversed(), sorted.joined(separator: " | "))

        // clean up: our own test artifacts only
        for u in trashLeftovers where u.path.contains("/.Trash/") { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: root)
        print("\n结果：\(pass) 通过，\(fail) 失败（清理了 \(trashLeftovers.count) 个测试产生的废纸篓项目）")
        return fail == 0 ? 0 : 1
    }
}
