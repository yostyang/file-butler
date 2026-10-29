import Foundation
import AppKit
import QuickLookThumbnailing

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// `FileButler --bench <dir>`: non-UI timing + memory for the data paths every view uses.
enum Bench {
    @discardableResult static func time<T>(_ label: String, _ f: () -> T) -> T {
        let t0 = CFAbsoluteTimeGetCurrent(); let r = f()
        print(String(format: "%-34@ %8.1f ms   footprint %6.1f MB", label as NSString, (CFAbsoluteTimeGetCurrent() - t0) * 1000, physFootprintMB()))
        return r
    }
    static func run(_ dir: URL) -> Int32 {
        print(String(format: "start footprint %.1f MB", physFootprintMB()))
        let legacyKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .tagNamesKey]
        // 与 v0.2 完全相同的读取方式：每项 standardize + 逐个 localizedTypeDescription + 保留属性缓存
        var legacyItems: [FileItem] = []
        let legacy: [URL] = time("v0.2 方式：列目录+读取属性") {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: legacyKeys, options: [.skipsHiddenFiles])) ?? []
            legacyItems = urls.map { raw in
                let u = raw.standardizedFileURL; let v = try? u.resourceValues(forKeys: Set(legacyKeys))
                return FileItem(url: u, name: u.lastPathComponent, isDir: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false, size: Int64(v?.fileSize ?? 0),
                                modified: v?.contentModificationDate, created: v?.creationDate, kind: v?.localizedTypeDescription ?? "", hidden: v?.isHidden ?? false, tags: v?.tagNames ?? [])
            }
            return urls
        }
        print("  v0.2 方式 \(legacyItems.count) 项"); legacyItems = []
        time("v0.2 方式：2000 个逐文件图标") { for u in legacy.prefix(2000) { _ = NSWorkspace.shared.icon(forFile: u.path) } }
        var items: [FileItem] = []
        for pass in 1...2 {
            items = time("列目录+读取属性 (第\(pass)次)") { loadDirectory(dir, hidden: false).items }
        }
        print("  \(items.count) 项")
        for k in SortKey.allCases { _ = time("排序 \(k.rawValue)") { sortItems(items, key: k, asc: true) } }
        for g in [GroupKey.kind, .date, .size, .name] { _ = time("分组 \(g.rawValue)") { groupItems(items, by: g) } }
        time("名称过滤 \"9\"") { items.filter { $0.name.localizedCaseInsensitiveContains("9") } }
        time("新版：2000 个列表图标") { for it in items.prefix(2000) { _ = ThumbCache.listIcon(it) } }
        let imgs = items.filter { $0.name.hasPrefix("img_") }.prefix(300).map { $0.url }
        time("300 张缩略图 128pt") {
            let g = DispatchGroup()
            for u in imgs {
                g.enter()
                ThumbCache.requestThumb(u, bucket: 128) { _ in g.leave() }
            }
            g.wait()
        }
        time("释放缓存后") { ThumbCache.purge(); return 0 }
        return 0
    }
}

/// `FileButler --opbench`：大文件 / 万级文件夹的后台文件操作耗时（只在 /tmp/fb-opbench 里，结束时清理，包括它放进废纸篓的项目）
enum OpBench {
    static func run() -> Int32 {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/fb-opbench"); try? fm.removeItem(at: root)
        let src = root.appendingPathComponent("源"), dst = root.appendingPathComponent("目标"), dst2 = root.appendingPathComponent("目标2")
        for d in [src, dst, dst2] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        // 2 GB 实际数据的文件（不是稀疏文件）
        let big = src.appendingPathComponent("大文件.bin")
        fm.createFile(atPath: big.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: big) { let chunk = Data(repeating: 0x5A, count: 64 << 20); for _ in 0..<32 { h.write(chunk) }; try? h.close() }
        // 1 万个小文件的文件夹
        let folder = src.appendingPathComponent("万个文件"); try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let small = Data(repeating: 1, count: 1024)
        for i in 0..<10000 { fm.createFile(atPath: folder.appendingPathComponent("f\(i).txt").path, contents: small) }
        func t(_ label: String, _ f: () -> Void) { let s = CFAbsoluteTimeGetCurrent(); f(); print(String(format: "OPBENCH %@ %.0f ms", label, (CFAbsoluteTimeGetCurrent() - s) * 1000)) }
        var trashed: [URL] = []
        t("拷贝 2GB 单文件（同卷，克隆）") { _ = FileOps.transfer([big], to: dst, mode: .copy) }
        t("移动 2GB 单文件（同卷）") { _ = FileOps.transfer([dst.appendingPathComponent("大文件.bin")], to: dst2, mode: .move) }
        t("移到废纸篓 2GB 单文件") { trashed += FileOps.trash([dst2.appendingPathComponent("大文件.bin")]).done.map { $0.1 } }
        t("拷贝 1 万文件的文件夹（同卷）") { _ = FileOps.transfer([folder], to: dst, mode: .copy) }
        t("移动 1 万文件的文件夹（同卷）") { _ = FileOps.transfer([dst.appendingPathComponent("万个文件")], to: dst2, mode: .move) }
        t("列出 1 万项（读取属性）") { _ = loadDirectory(dst2.appendingPathComponent("万个文件"), hidden: false) }
        t("移到废纸篓 1 万文件的文件夹") { trashed += FileOps.trash([dst2.appendingPathComponent("万个文件")]).done.map { $0.1 } }
        let files = (0..<10000).map { folder.appendingPathComponent("f\($0).txt") }
        t("拷贝 1 万个文件（逐项）") { _ = FileOps.transfer(files, to: dst, mode: .copy) }
        t("移动 1 万个文件（逐项）") { _ = FileOps.transfer((0..<10000).map { dst.appendingPathComponent("f\($0).txt") }, to: dst2, mode: .move) }
        t("移到废纸篓 1 万个文件（逐项）") { trashed += FileOps.trash((0..<10000).map { dst2.appendingPathComponent("f\($0).txt") }).done.map { $0.1 } }
        for u in trashed { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: root)
        print("OPBENCH 已清理 \(trashed.count) 个废纸篓项目")
        return 0
    }
}
