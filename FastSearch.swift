import Foundation
import Darwin

/// 极速文件名搜索（不走 Spotlight）：
/// - 子文件夹 / 文件夹内条件搜索：后台递归枚举（FileManager 内部走 getattrlistbulk 批量读取）
/// - 整台 Mac：searchfs(2) 直接扫 APFS 卷宗目录（参考 github.com/sveinbjornt/searchfs，
///   比递归快 ~100 倍；只返回有权限访问的项，无需 root）
/// 两条路径都把结果分批流式回主线程——输入后几十毫秒就能看到第一批结果。
/// 内容搜索 / 标签搜索仍需 Spotlight（要走索引），由调用方分流。
enum FastSearch {
    typealias Batch = ([URL]) -> Void

    // MARK: 递归枚举（.subfolders / .folder + 条件）

    static func enumerate(root: URL, query: String, showHidden: Bool,
                          isCancelled: @escaping () -> Bool,
                          onBatch: @escaping Batch, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                       options: showHidden ? [] : [.skipsHiddenFiles]) else { done(); return }
            var batch: [URL] = []
            var last = Date()
            func flush() {
                if !batch.isEmpty { onBatch(batch); batch = []; last = Date() }
            }
            for case let u as URL in e {
                if isCancelled() { break }
                if query.isEmpty || u.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    batch.append(u)
                    if batch.count >= 256 || Date().timeIntervalSince(last) > 0.1 { flush() }
                }
            }
            flush()
            done()
        }
    }

    // MARK: searchfs 卷宗目录搜索（.mac）

    private typealias SearchFSFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt>, UInt32, UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias FSGetPathFn = @convention(c) (UnsafeMutablePointer<CChar>, Int, UnsafeRawPointer, UInt64) -> Int
    private static let sfs: SearchFSFn? = dlsym(dlopen(nil, RTLD_NOW), "searchfs").map { unsafeBitCast($0, to: SearchFSFn.self) }
    private static let fgp: FSGetPathFn? = dlsym(dlopen(nil, RTLD_NOW), "fsgetpath").map { unsafeBitCast($0, to: FSGetPathFn.self) }
    static var catalogSupported: Bool { sfs != nil && fgp != nil }

    /// 逐卷调用 searchfs；done(ok=false) 表示不支持/出错，调用方回退 Spotlight
    static func catalogSearch(query: String, showHidden: Bool, limit: Int,
                              isCancelled: @escaping () -> Bool,
                              onBatch: @escaping Batch, done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            // "/" = 系统卷（只读），"/System/Volumes/Data" = 数据卷（firmlink，用户文件都在这里）
            for vol in ["/", "/System/Volumes/Data"] where !isCancelled() {
                if searchVolume(vol, query: query, showHidden: showHidden, limit: limit, isCancelled: isCancelled, onBatch: onBatch) { ok = true }
            }
            done(ok)
        }
    }

    private static func attrlist(_ p: UnsafeMutableRawPointer, _ common: UInt32) {
        // struct attrlist { u16 bitmapcount; u16 reserved; 5×u32 groups }，24 字节
        p.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        p.storeBytes(of: UInt16(5), as: UInt16.self)              // ATTR_BIT_MAP_COUNT
        p.storeBytes(of: common, toByteOffset: 4, as: UInt32.self) // commonattr
    }

    private static func searchVolume(_ vol: String, query: String, showHidden: Bool, limit: Int,
                                     isCancelled: () -> Bool, onBatch: Batch) -> Bool {
        guard let sfs = sfs, let fgp = fgp else { return false }
        let SRCHFS_START: UInt32 = 0x1, PARTIAL: UInt32 = 0x2, DIRS: UInt32 = 0x4, FILES: UInt32 = 0x8, INVIS: UInt32 = 0x20
        let CMN_NAME: UInt32 = 0x1, CMN_FSID: UInt32 = 0x4, CMN_OBJID: UInt32 = 0x20
        let EAGAIN = Int32(35), EBUSY = Int32(16)
        let maxM = 64
        // fssearchblock 布局（104B）：ptr×2, size, ulong, timeval(16B), ptr×2, size×2, attrlist(24B)
        let block = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: 8); defer { block.deallocate() }
        let retAttrs = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8); defer { retAttrs.deallocate() }
        let retBuf = UnsafeMutableRawPointer.allocate(byteCount: 20 * maxM, alignment: 8); defer { retBuf.deallocate() }
        let p1 = UnsafeMutableRawPointer.allocate(byteCount: 12 + 1024, alignment: 8); defer { p1.deallocate() }
        let p2 = UnsafeMutableRawPointer.allocate(byteCount: 12, alignment: 8); defer { p2.deallocate() }
        let state = UnsafeMutableRawPointer.allocate(byteCount: 556, alignment: 4); defer { state.deallocate() }
        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 4096); defer { pathBuf.deallocate() }
        func putPtr(_ off: Int, _ v: UnsafeMutableRawPointer) { block.storeBytes(of: UInt64(UInt(bitPattern: v)), toByteOffset: off, as: UInt64.self) }
        // searchparams1：名称（packed_name_attr = u32 size + attrreference(offset,len) + name）
        var name = Array(query.utf8.prefix(1000)); name.append(0)
        let size1 = 8 + name.count
        p1.storeBytes(of: UInt32(size1), as: UInt32.self)
        p1.storeBytes(of: Int32(8), toByteOffset: 4, as: Int32.self)
        p1.storeBytes(of: UInt32(name.count), toByteOffset: 8, as: UInt32.self)
        (p1 + 12).initializeMemory(as: UInt8.self, from: name, count: name.count)
        // searchparams2：空的 attrreference
        p2.storeBytes(of: UInt32(8), as: UInt32.self)
        p2.storeBytes(of: Int32(8), toByteOffset: 4, as: Int32.self)
        p2.storeBytes(of: UInt32(0), toByteOffset: 8, as: UInt32.self)
        // fssearchblock
        block.initializeMemory(as: UInt8.self, repeating: 0, count: 112)
        attrlist(retAttrs, CMN_FSID | CMN_OBJID)
        putPtr(0, retAttrs); putPtr(8, retBuf)
        block.storeBytes(of: UInt64(20 * maxM), toByteOffset: 16, as: UInt64.self)   // returnbuffersize
        block.storeBytes(of: UInt64(maxM), toByteOffset: 24, as: UInt64.self)        // maxmatches
        block.storeBytes(of: Int64(1), toByteOffset: 32, as: Int64.self)             // timelimit.tv_sec = 1
        putPtr(48, p1); block.storeBytes(of: UInt64(size1 + 4), toByteOffset: 56, as: UInt64.self)
        putPtr(64, p2); block.storeBytes(of: UInt64(12), toByteOffset: 72, as: UInt64.self)
        attrlist(block + 80, CMN_NAME)                                                // searchattrs
        var options: UInt32 = SRCHFS_START | FILES | DIRS | PARTIAL | (showHidden ? 0 : INVIS)
        var matches: UInt = 0, found = 0, ebusy = 0
        var err = Int32(0)
    restart:
        while true {
            state.initializeMemory(as: UInt8.self, repeating: 0, count: 556)
            repeat {
                if isCancelled() { return true }
                err = sfs(vol, block, &matches, 0, options, state)
                if err == -1 { err = errno }
                if (err == 0 || err == EAGAIN), matches > 0 {
                    var ptr = retBuf, urls: [URL] = []
                    for _ in 0..<matches {
                        let sz = Int(ptr.load(as: UInt32.self))                   // packed_result.size
                        let objno = UInt64(ptr.load(fromByteOffset: 12, as: UInt32.self))
                        let gen = UInt64(ptr.load(fromByteOffset: 16, as: UInt32.self))
                        if fgp(pathBuf, 4096, ptr + 4, objno | (gen << 32)) > 0 {   // fsid_t* at +4
                            urls.append(URL(fileURLWithPath: String(cString: pathBuf)))
                        }
                        ptr += max(sz, 20)
                    }
                    if !urls.isEmpty {
                        onBatch(urls); found += urls.count
                        if found >= limit { return true }
                    }
                }
                if err == EBUSY { ebusy += 1; if ebusy < 5 { continue restart }; return found > 0 }
                if err != 0, err != EAGAIN { return found > 0 }
                options &= ~SRCHFS_START
            } while err == EAGAIN
            break
        }
        return true
    }
}
