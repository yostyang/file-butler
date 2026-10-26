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
