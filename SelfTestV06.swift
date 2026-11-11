import AppKit
import Foundation

/// v0.6 自测：批量重命名规则 / 冲突 / 撤销，文件架，命令面板的匹配、命令和可取消的扫描。只在 /tmp/fb-test 里操作。
extension SelfTest {
    static func v06(root: URL, report: (String, Bool, String) -> Void) {
        func check(_ n: String, _ ok: Bool, _ note: String = "") { report(n, ok, note) }
        let fm = FileManager.default
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        func names(_ d: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
        func touch(_ u: URL, _ s: String = "x") { try? s.write(to: u, atomically: true, encoding: .utf8) }

        // ===== 批量重命名：规则 =====
        var r = RenameRule()
        r.find = "照片"; r.replace = "旅行"
        check("批量重命名：替换文字（保留扩展名）", BatchRename.newName("照片 1.JPG", folderLike: false, index: 0, rule: r) == "旅行 1.JPG", BatchRename.newName("照片 1.JPG", folderLike: false, index: 0, rule: r))
        r = RenameRule(); r.find = "jpg"; r.replace = "png"
        check("批量重命名：保留扩展名时不改扩展名", BatchRename.newName("a.jpg", folderLike: false, index: 0, rule: r) == "a.jpg", BatchRename.newName("a.jpg", folderLike: false, index: 0, rule: r))
        r.keepExt = false
        check("批量重命名：不保留扩展名时整个名称参与替换", BatchRename.newName("a.jpg", folderLike: false, index: 0, rule: r) == "a.png")
        r = RenameRule(); r.find = "abc"; r.replace = "X"
        check("批量重命名：默认不区分大小写", BatchRename.newName("ABC-abc.txt", folderLike: false, index: 0, rule: r) == "X-X.txt")
        r.caseSensitive = true
        check("批量重命名：区分大小写", BatchRename.newName("ABC-abc.txt", folderLike: false, index: 0, rule: r) == "ABC-X.txt")
        r = RenameRule(); r.prefix = "2026-"; r.suffix = "_终稿"
        check("批量重命名：前缀 + 后缀（加在扩展名前）", BatchRename.newName("报告.final.pdf", folderLike: false, index: 0, rule: r) == "2026-报告.final_终稿.pdf", BatchRename.newName("报告.final.pdf", folderLike: false, index: 0, rule: r))
        r = RenameRule(); r.numberMode = .suffix; r.start = 9; r.digits = 3
        check("批量重命名：名称后加序号（起始 9、3 位）", (0..<3).map { BatchRename.newName("图.png", folderLike: false, index: $0, rule: r) } == ["图 009.png", "图 010.png", "图 011.png"])
        r = RenameRule(); r.numberMode = .format; r.format = "旅行"; r.separator = "-"; r.digits = 2
        check("批量重命名：统一名称 + 序号", BatchRename.newName("IMG_1234.HEIC", folderLike: false, index: 4, rule: r) == "旅行-05.HEIC")
        r = RenameRule(); r.suffix = "_v2"
        check("批量重命名：文件夹不拆扩展名 / 点开头的名称不拆", BatchRename.newName("项目.2026", folderLike: true, index: 0, rule: r) == "项目.2026_v2" && BatchRename.newName(".env", folderLike: false, index: 0, rule: r) == ".env_v2")
        check("批量重命名：包（.app）保留扩展名", BatchRename.newName("Foo.app", folderLike: false, index: 0, rule: r) == "Foo_v2.app")
        check("批量重命名：无效名称（空、/、:、点开头、超长）", BatchRename.validate("") != nil && BatchRename.validate("a/b") != nil && BatchRename.validate("a:b") != nil && BatchRename.validate(".x") != nil && BatchRename.validate(String(repeating: "长", count: 90)) != nil && BatchRename.validate("正常.txt") == nil)

        // ===== 批量重命名：预览里的冲突 =====
        let B = root.appendingPathComponent("批量改名"); try? fm.createDirectory(at: B, withIntermediateDirectories: true)
        for n in ["照片 1.jpg", "照片 2.jpg", "照片 3.jpg", "已有.jpg", "说明.md"] { touch(B.appendingPathComponent(n), n) }
        let three = ["照片 1.jpg", "照片 2.jpg", "照片 3.jpg"].map { (url: B.appendingPathComponent($0), folderLike: false) }
        r = RenameRule(); r.find = "照片"; r.replace = "旅行"
        var rows = BatchRename.plan(three, rule: r)
        check("预览：3 项都可以改名", rows.map { $0.new } == ["旅行 1.jpg", "旅行 2.jpg", "旅行 3.jpg"] && rows.allSatisfy { $0.status == .ok })
        r = RenameRule(); r.find = "照片 2"; r.replace = "照片 1"
        rows = BatchRename.plan(three, rule: r)
        check("预览：两项得到同一个名称 → 两项都标出冲突", rows[0].status.isBlocking && rows[1].status.isBlocking && rows[2].status == .unchanged && (rows[1].status.message ?? "").contains("同一个名称"), rows.map { "\($0.new):\($0.status)" }.joined(separator: " "))
        r = RenameRule(); r.find = "照片 3"; r.replace = "已有"
        rows = BatchRename.plan(three, rule: r)
        check("预览：和文件夹里已有的项目重名 → 访达的提示", rows[2].status == .conflict("名称“已有.jpg”已被使用。请选取一个不同的名称。"), "\(rows[2].status)")
        r = RenameRule(); r.find = "照片"; r.replace = "a/b"
        rows = BatchRename.plan(three, rule: r)
        check("预览：名称含 / → 无效，拒绝执行", rows.allSatisfy { $0.status.isBlocking } && (try? BatchRename.apply(rows)) == nil && names(B).contains("照片 1.jpg"))
        let blocked = rows

        // ===== 批量重命名：执行 + 一次撤销 =====
        r = RenameRule(); r.numberMode = .format; r.format = "旅行"; r.digits = 2
        rows = BatchRename.plan(three, rule: r)
        do {
            let pairs = try BatchRename.apply(rows)
            check("执行：3 项改名为 旅行 01/02/03", names(B) == ["已有.jpg", "说明.md", "旅行 01.jpg", "旅行 02.jpg", "旅行 03.jpg"].sorted() && pairs.count == 3, names(B).joined(separator: ","))
            check("执行：内容跟着走（没有覆盖别的文件）", ((try? String(contentsOf: B.appendingPathComponent("旅行 02.jpg"), encoding: .utf8)) ?? "") == "照片 2.jpg")
            try FileOps.undo(.renamedBatch(pairs))
            check("撤销：整批一次改回原名", names(B) == ["照片 1.jpg", "照片 2.jpg", "照片 3.jpg", "已有.jpg", "说明.md"].sorted(), names(B).joined(separator: ","))
        } catch { check("执行批量重命名", false, error.localizedDescription) }
        _ = blocked
        // 链式改名（照片 2 → 照片 3，照片 3 → 照片 4）：改成批内另一项的旧名字不算冲突
        let chain = [(url: B.appendingPathComponent("照片 2.jpg"), folderLike: false), (url: B.appendingPathComponent("照片 3.jpg"), folderLike: false)]
        r = RenameRule(); r.numberMode = .format; r.format = "照片"; r.start = 3
        let planned = BatchRename.plan(chain, rule: r)
        check("预览：改成批内另一项的旧名字不算冲突（链式改名）", planned.map { $0.new } == ["照片 3.jpg", "照片 4.jpg"] && planned.allSatisfy { $0.status == .ok }, planned.map { "\($0.new):\($0.status)" }.joined(separator: " "))
        do {
            let pairs = try BatchRename.apply(planned)
            let c3 = (try? String(contentsOf: B.appendingPathComponent("照片 3.jpg"), encoding: .utf8)) ?? ""
            check("执行：链式改名不互相覆盖", c3 == "照片 2.jpg" && names(B).contains("照片 4.jpg") && !names(B).contains("照片 2.jpg"), names(B).joined(separator: ","))
            try BatchRename.undo(pairs)
            check("撤销链式改名", ((try? String(contentsOf: B.appendingPathComponent("照片 3.jpg"), encoding: .utf8)) ?? "") == "照片 3.jpg" && names(B).contains("照片 2.jpg"))
        } catch { check("链式改名", false, error.localizedDescription) }
        // 互换名称（a ↔ b）：两步改名不会互相覆盖
        let swapRows = [RenameRow(id: 0, src: B.appendingPathComponent("照片 1.jpg"), old: "照片 1.jpg", new: "照片 2.jpg", status: .ok), RenameRow(id: 1, src: B.appendingPathComponent("照片 2.jpg"), old: "照片 2.jpg", new: "照片 1.jpg", status: .ok)]
        do {
            let pairs = try BatchRename.apply(swapRows)
            let c1 = (try? String(contentsOf: B.appendingPathComponent("照片 1.jpg"), encoding: .utf8)) ?? ""
            check("执行：两个文件互换名称", c1 == "照片 2.jpg" && names(B).count == 5, c1)
            try BatchRename.undo(pairs)
            check("撤销互换", ((try? String(contentsOf: B.appendingPathComponent("照片 1.jpg"), encoding: .utf8)) ?? "") == "照片 1.jpg")
        } catch { check("互换名称", false, error.localizedDescription) }
        // 只改大小写
        do {
            let u = B.appendingPathComponent("说明.md")
            let pairs = try BatchRename.apply([RenameRow(id: 0, src: u, old: "说明.md", new: "说明.MD", status: .ok)])
            check("执行：只改大小写（说明.md → 说明.MD）", names(B).contains("说明.MD") && !names(B).contains("说明.md"), names(B).joined(separator: ","))
            try BatchRename.undo(pairs)
            check("撤销只改大小写", names(B).contains("说明.md"))
        } catch { check("只改大小写", false, error.localizedDescription) }
        // 执行时目标被别的程序占用 → 不覆盖，全部回滚
        do {
            r = RenameRule(); r.find = "照片"; r.replace = "回滚"
            let rr = BatchRename.plan(three, rule: r)
            touch(B.appendingPathComponent("回滚 2.jpg"), "别人刚写的")   // 预览之后才出现
            let res = Result { try BatchRename.apply(rr) }
            let after = names(B)
            var ok = false; if case .failure = res { ok = true }
            check("执行时目标被占用 → 报错、不覆盖、已改的全部改回", ok && after.contains("照片 1.jpg") && after.contains("照片 2.jpg") && after.contains("照片 3.jpg") && !after.contains("回滚 1.jpg") && ((try? String(contentsOf: B.appendingPathComponent("回滚 2.jpg"), encoding: .utf8)) ?? "") == "别人刚写的" && !after.contains(where: { $0.hasPrefix(".fb-rename") }), after.joined(separator: ","))
            try? fm.removeItem(at: B.appendingPathComponent("回滚 2.jpg"))
        }
        // 大批量预览：2000 项、可取消
        let many = (0..<2000).map { (url: B.appendingPathComponent("f\($0).txt"), folderLike: false) }
        var t0 = Date()
        var mr = RenameRule(); mr.numberMode = .format; mr.format = "新"; mr.digits = 4
        let bigRows = BatchRename.plan(many, rule: mr, exists: { _ in false })
        let planMs = Date().timeIntervalSince(t0) * 1000
        check("预览：2000 项计算（后台线程）", bigRows.count == 2000 && bigRows.allSatisfy { $0.status == .ok }, String(format: "%.1fms", planMs))
        let tok = CancelToken(); tok.cancel()
        check("预览：取消后不再计算", BatchRename.plan(many, rule: mr, exists: { _ in false }, cancelled: { tok.isCancelled }).isEmpty)

        // ===== 文件架 =====
        let S1 = root.appendingPathComponent("架甲"), S2 = root.appendingPathComponent("架乙"), Dst = root.appendingPathComponent("架目标")
        for d in [S1, S2, Dst] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let x1 = S1.appendingPathComponent("x1.txt"), x2 = S2.appendingPathComponent("x2.txt")
        touch(x1, "1"); touch(x2, "2")
        let key = "shelfItems-selftest"
        UserDefaults.standard.removeObject(forKey: key)
        let shelf = ShelfModel(storeKey: key)
        check("文件架：从两个文件夹加入，按路径去重", shelf.add([x1, x2]) == 2 && shelf.add([x1]) == 0 && shelf.items.count == 2)
        shelf.remove([x1])
        check("文件架：移出只改列表，文件还在原处", shelf.items.count == 1 && exists(x1) && exists(x2))
        shelf.add([x1])
        let reloaded = ShelfModel(storeKey: key)
        check("文件架：重新打开后还记得", reloaded.items.map { $0.lastPathComponent } == ["x2.txt", "x1.txt"], reloaded.items.map { $0.lastPathComponent }.joined(separator: ","))
        // 一起拷贝（与粘贴同一入口 FileOps.transfer）
        var tr = FileOps.transfer(shelf.items, to: Dst, mode: .copy)
        check("文件架：一起拷贝到目标文件夹，原件不动", exists(Dst.appendingPathComponent("x1.txt")) && exists(Dst.appendingPathComponent("x2.txt")) && exists(x1) && exists(x2) && tr.copied.count == 2)
        tr = FileOps.transfer(shelf.items, to: Dst, mode: .copy, resolve: { _, _ in (.keepBoth, true) })
        check("文件架：再拷贝遇到同名 → 保留两者（与访达一致）", exists(Dst.appendingPathComponent("x1 2.txt")) && exists(Dst.appendingPathComponent("x2 2.txt")))
        for u in ((try? FileOps.undo(.created(tr.copied))) ?? []) where u.path.contains("/.Trash/") { try? fm.removeItem(at: u) }
        for n in ["x1.txt", "x2.txt"] { try? fm.removeItem(at: Dst.appendingPathComponent(n)) }
        tr = FileOps.transfer(shelf.items, to: Dst, mode: .move)
        shelf.relocate(tr.moved)
        check("文件架：一起移动，文件架指向新位置", !exists(x1) && !exists(x2) && shelf.items.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "架目标" && exists($0) }, shelf.items.map { $0.path }.joined(separator: ","))
        _ = try? FileOps.undo(.moved(tr.moved))
        check("文件架：撤销移动 → 回到原文件夹", exists(x1) && exists(x2))
        check("文件架：已不存在的项目会被清掉", shelf.prune() == 2 && shelf.items.isEmpty)
        shelf.add([x1, x2]); shelf.clear()
        check("文件架：清空不碰文件", shelf.items.isEmpty && exists(x1) && exists(x2))
        UserDefaults.standard.removeObject(forKey: key)

        // ===== 命令面板 =====
        let s = PaletteEngine.score
        check("命令面板：匹配分数 完全 > 前缀 > 包含 > 模糊，不匹配为 nil",
              s("说明", "说明")! > s("说明", "说明.txt")! && s("说明", "说明.txt")! > s("说明", "项目说明.txt")! && s("说明", "项目说明.txt")! > s("smt", "summit.txt")! && s("xyz", "说明.txt") == nil)
        check("命令面板：不区分大小写", s("readme", "README.md") != nil)
        check("命令面板：「~」路径", PaletteEngine.pathQuery("~")?.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path && PaletteEngine.pathQuery("/不存在的路径-fb") == nil)
        let app = AppState()
        let tab = app.panes[0].tab
        tab.selection = []
        var titles = PaletteEngine.commands(app).map { $0.title }
        let need = ["新建文件夹", "新建标签页", "前往文件夹…", "搜索当前文件夹", "空间分析"]
        check("命令面板：常用命令都在", need.allSatisfy { titles.contains($0) } && titles.contains { $0.hasSuffix("显示方式") } && titles.contains { $0.hasSuffix("隐藏文件") } && titles.contains { $0.contains("文件架") }, titles.joined(separator: "|"))
        check("命令面板：没有选中项目时不列出「批量重命名」", !titles.contains { $0.hasPrefix("批量重命名") })
        tab.selection = [x1, x2]
        titles = PaletteEngine.commands(app).map { $0.title }
        check("命令面板：选中 2 项时有「批量重命名 2 个项目…」和「加入文件架」", titles.contains("批量重命名 2 个项目…") && titles.contains("把 2 个项目加入文件架"), titles.joined(separator: "|"))
        let ranked = PaletteEngine.rank("新建文件", commands: PaletteEngine.commands(app), files: [], app: app)
        check("命令面板：输入「新建文件」第一项是「新建文件夹」", ranked.first?.title == "新建文件夹", ranked.prefix(3).map { $0.title }.joined(separator: "|"))
        let rankedEn = PaletteEngine.rank("new folder", commands: PaletteEngine.commands(app), files: [], app: app)
        check("命令面板：英文关键词也能找到命令", rankedEn.first?.title == "新建文件夹", rankedEn.prefix(3).map { $0.title }.joined(separator: "|"))
        tab.selection = []
        // 当前文件夹下几层的扫描：能找到、可取消、有上限
        let deep = root.appendingPathComponent("深/一/二"); try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        touch(deep.appendingPathComponent("藏得很深的文件.txt"))
        t0 = Date()
        let found = PaletteEngine.deepScan(root: root, query: "藏得很深", showHidden: false, token: CancelToken())
        check("命令面板：找到当前文件夹下 3 层的文件", found.hits.map { $0.url.lastPathComponent } == ["藏得很深的文件.txt"], String(format: "访问 %d 项，%.1fms", found.visited, Date().timeIntervalSince(t0) * 1000))
        let shallow = PaletteEngine.deepScan(root: root, query: "藏得很深", showHidden: false, token: CancelToken(), maxDepth: 2)
        check("命令面板：层数上限生效", shallow.hits.isEmpty)
        let c2 = CancelToken(); c2.cancel()
        let cancelled = PaletteEngine.deepScan(root: root, query: "藏得很深", showHidden: false, token: c2)
        check("命令面板：取消后立即停止、不返回结果", cancelled.hits.isEmpty && cancelled.visited <= 1, "访问 \(cancelled.visited) 项")
        let capped = PaletteEngine.deepScan(root: root, query: "f", showHidden: false, token: CancelToken(), maxVisit: 10)
        check("命令面板：访问数量上限生效", capped.visited <= 11, "访问 \(capped.visited) 项")
        let pm = PaletteModel(); pm.app = app
        pm.open(); let tk = pm.token; pm.setQuery("藏得"); let tk2 = pm.token; pm.close(refocus: false)
        check("命令面板：关闭时取消正在进行的扫描", tk.isCancelled && tk2.isCancelled && !pm.visible && pm.results.isEmpty)
        try? fm.removeItem(at: root.appendingPathComponent("深"))
    }
}
