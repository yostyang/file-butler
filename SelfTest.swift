import Foundation

/// `FileButler --selftest`: exercises the file operations in /tmp/fb-test only, prints PASS/FAIL, exits.
enum SelfTest {
    static func run() -> Int32 {
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
        check("同名拷贝自动加「副本」", r.copied.first?.lastPathComponent == "file1 副本.txt", r.copied.first?.lastPathComponent ?? "")
        if let more = try? FileOps.undo(.created(r.copied)) { trashLeftovers += more }
        check("撤销拷贝", !exists(b.appendingPathComponent("file1 副本.txt")))

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
        r = FileOps.transfer([f1], to: b, mode: .move)
        check("移动遇到同名不覆盖", !r.errs.isEmpty && exists(f1) && text(b.appendingPathComponent("file1.txt")) == "x")

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
