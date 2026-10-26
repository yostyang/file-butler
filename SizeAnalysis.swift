import SwiftUI
import AppKit

final class SizeNode: Identifiable {
    let id = UUID(); let url: URL; let name: String; let isDir: Bool
    var size: Int64 = 0, files = 0, isAggregate = false
    var children: [SizeNode] = []
    weak var parent: SizeNode?
    init(url: URL, name: String, isDir: Bool) { self.url = url; self.name = name; self.isDir = isDir }
}

final class SizeScanner: ObservableObject {
    @Published var root: SizeNode?
    @Published var scanning = false
    @Published var scannedFiles = 0
    @Published var scannedBytes: Int64 = 0
    @Published var currentPath = ""
    @Published var largestURL: URL?
    @Published var largestSize: Int64 = 0
    @Published var wasCancelled = false
    private var cancelled = false
    static let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/net", "/home"]

    func cancel() { cancelled = true }
    func start(_ url: URL) {
        cancelled = false; scanning = true; root = nil; scannedFiles = 0; scannedBytes = 0; wasCancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            var count = 0, bytes: Int64 = 0, lastTick = Date()
            var largest: (URL, Int64)?
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            func scan(_ u: URL, _ parent: SizeNode?) -> SizeNode {
                let node = SizeNode(url: u, name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent, isDir: true); node.parent = parent
                if self.cancelled || (parent != nil && SizeScanner.skip.contains(u.path)) { return node }
                guard let list = try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: keys, options: []) else { return node }
                var files: [SizeNode] = []
                for c in list {
                    if self.cancelled { break }
                    let v = try? c.resourceValues(forKeys: Set(keys))
                    if v?.isSymbolicLink == true { continue }
                    if v?.isDirectory == true {
                        let ch = scan(c, node); node.size += ch.size; node.files += ch.files; node.children.append(ch)
                    } else {
                        let s = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
                        let f = SizeNode(url: c, name: c.lastPathComponent, isDir: false); f.size = s; f.files = 1; f.parent = node
                        files.append(f); node.size += s; node.files += 1; count += 1; bytes += s
                        if s > (largest?.1 ?? -1) { largest = (c, s) }
                    }
                }
                files.sort { $0.size > $1.size }
                if files.count > 40 {
                    let rest = files[40...]
                    let agg = SizeNode(url: u, name: "其他 \(rest.count) 个文件", isDir: false)
                    agg.isAggregate = true; agg.size = rest.reduce(0) { $0 + $1.size }; agg.files = rest.count; agg.parent = node
                    files = Array(files[..<40]) + [agg]
                }
                node.children += files
                node.children.sort { $0.size > $1.size }
                if Date().timeIntervalSince(lastTick) > 0.15 {
                    lastTick = Date(); let cc = count, bb = bytes, p = u.path
                    DispatchQueue.main.async { self.scannedFiles = cc; self.scannedBytes = bb; self.currentPath = p }
                }
                return node
            }
            let r = scan(url, nil)
            DispatchQueue.main.async {
                self.wasCancelled = self.cancelled; self.scanning = false; self.root = r
                self.scannedFiles = count; self.scannedBytes = bytes
                self.largestURL = largest?.0; self.largestSize = largest?.1 ?? 0
            }
        }
    }
}

let sizePalette: [Color] = [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.18, green: 0.70, blue: 0.96), Color(red: 0.55, green: 0.35, blue: 0.90),
                            Color(red: 0.20, green: 0.80, blue: 0.75), Color(red: 0.95, green: 0.55, blue: 0.30), Color(red: 0.92, green: 0.40, blue: 0.60),
                            Color(red: 0.45, green: 0.75, blue: 0.35), Color(red: 0.95, green: 0.75, blue: 0.25), Color(red: 0.30, green: 0.50, blue: 0.95)]
func colorFor(_ n: SizeNode, _ i: Int) -> Color { n.isDir ? sizePalette[i % sizePalette.count] : Color.gray.opacity(0.55) }

struct SizeAnalysisView: View {
    let rootURL: URL
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @StateObject var scanner = SizeScanner()
    @State var current: SizeNode?
    @State var rev = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.pie.fill").font(.title2).foregroundStyle(accentGrad)
                VStack(alignment: .leading, spacing: 2) {
                    Text("空间分析").font(.title3.bold())
                    Text(rootURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if scanner.scanning { Button("取消扫描") { scanner.cancel() } }
                else { Button("重新扫描") { current = nil; scanner.start(rootURL) } }
                Button("完成") { scanner.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if scanner.scanning {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("已扫描 \(scanner.scannedFiles) 个文件 · \(fmtBytes(scanner.scannedBytes))").font(.headline).monospacedDigit()
                    Text(scanner.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 600)
                    Button("取消扫描") { scanner.cancel() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = scanner.root {
                let node = current ?? root
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        stat("总大小", fmtBytes(root.size))
                        stat("文件数", "\(root.files)")
                        stat("最大文件", scanner.largestURL.map { "\($0.lastPathComponent)（\(fmtBytes(scanner.largestSize))）" } ?? "--")
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    if scanner.wasCancelled { Text("扫描已取消，以下是部分结果。").font(.caption).foregroundStyle(.orange) }
                    breadcrumb(node).padding(.horizontal, 16).padding(.bottom, 6)
                    Divider()
                    HStack(spacing: 0) {
                        SunburstView(node: node, rev: rev) { n in drill(n) }.frame(width: 320).padding(12)
                        Divider()
                        list(node)
                    }
                }.id(rev)
            } else { Spacer() }
        }
        .frame(width: 900, height: 620)
        .onAppear { scanner.start(rootURL) }
        .onDisappear { scanner.cancel() }
    }

    func drill(_ n: SizeNode) { if n.isDir && !n.children.isEmpty { current = n } }

    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    func breadcrumb(_ node: SizeNode) -> some View {
        var chain: [SizeNode] = []; var n: SizeNode? = node
        while let x = n { chain.insert(x, at: 0); n = x.parent }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Button(c.name) { current = c }.buttonStyle(.plain).font(.system(size: 12, weight: c === node ? .semibold : .regular))
                        .foregroundStyle(c === node ? AnyShapeStyle(accentA) : AnyShapeStyle(.primary))
                }
            }
        }
    }

    func list(_ node: SizeNode) -> some View {
        List {
            ForEach(Array(node.children.enumerated()), id: \.element.id) { i, c in
                let frac = node.size > 0 ? Double(c.size) / Double(node.size) : 0
                HStack(spacing: 10) {
                    Image(nsImage: c.isAggregate ? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)! : NSWorkspace.shared.icon(forFile: c.url.path))
                        .resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.name).lineLimit(1).truncationMode(.middle)
                            if c.isDir { Text("\(c.files) 个文件").font(.caption2).foregroundStyle(.secondary) }
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(colorFor(c, i)).frame(width: max(2, g.size.width * frac))
                            }
                        }.frame(height: 5)
                    }
                    Text(String(format: "%.1f%%", frac * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    Text(fmtBytes(c.size)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    if c.isDir && !c.children.isEmpty { Image(systemName: "chevron.right").foregroundStyle(.tertiary) } else { Color.clear.frame(width: 8) }
                }
                .padding(.vertical, 3).contentShape(Rectangle())
                .onTapGesture { drill(c) }
                .contextMenu {
                    if !c.isAggregate {
                        if c.isDir && !c.children.isEmpty { Button("进入") { drill(c) } }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
                        Button("在文件管家中定位") { scanner.cancel(); dismiss(); app.go(c.url.deletingLastPathComponent()); app.activeTab.selection = [c.url.standardizedFileURL] }
                        Button("拷贝路径") { copyPaths([c.url]) }
                        Divider()
                        Button("移到废纸篓（可撤销）") { trash(c) }
                    }
                }
            }
        }.listStyle(.inset)
    }

    func trash(_ c: SizeNode) {
        let before = app.undoStack.count
        app.trash([c.url])
        guard app.undoStack.count > before, let p = c.parent else { return }
        p.children.removeAll { $0 === c }
        var a: SizeNode? = p
        while let x = a { x.size -= c.size; x.files -= c.files; a = x.parent }
        rev += 1
    }
}

struct SunburstView: View {
    let node: SizeNode, rev: Int
    let onSelect: (SizeNode) -> Void
    struct Seg { let node: SizeNode; let r0, r1: CGFloat; let a0, a1: Double; let color: Color }

    func layout(_ side: CGFloat) -> [Seg] {
        var segs: [Seg] = []
        guard node.size > 0 else { return segs }
        let r0 = side * 0.20, r1 = side * 0.35, r2 = side * 0.49
        var a = -Double.pi / 2
        for (i, c) in node.children.enumerated() {
            let span = Double(c.size) / Double(node.size) * 2 * .pi
            if span < 0.004 { a += span; continue }
            let col = colorFor(c, i)
            segs.append(Seg(node: c, r0: r0, r1: r1, a0: a, a1: a + span, color: col))
            if c.isDir && c.size > 0 && span > 0.03 {
                var b = a
                for g in c.children {
                    let s2 = Double(g.size) / Double(c.size) * span
                    if s2 > 0.004 { segs.append(Seg(node: g, r0: r1 + 2, r1: r2, a0: b, a1: b + s2, color: col.opacity(g.isDir ? 0.65 : 0.35))) }
                    b += s2
                }
            }
            a += span
        }
        return segs
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ctr = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let segs = layout(side)
            ZStack {
                Canvas { ctx, _ in
                    for s in segs {
                        var p = Path()
                        p.addArc(center: ctr, radius: s.r1, startAngle: .radians(s.a0), endAngle: .radians(s.a1), clockwise: false)
                        p.addArc(center: ctr, radius: s.r0, startAngle: .radians(s.a1), endAngle: .radians(s.a0), clockwise: true)
                        p.closeSubpath()
                        ctx.fill(p, with: .color(s.color))
                        ctx.stroke(p, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
                    }
                }
                VStack(spacing: 2) {
                    Text(fmtBytes(node.size)).font(.system(size: 16, weight: .bold)).monospacedDigit()
                    Text(node.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: side * 0.36)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                let dx = v.location.x - ctr.x, dy = v.location.y - ctr.y
                let r = sqrt(dx * dx + dy * dy)
                var ang = atan2(Double(dy), Double(dx)); if ang < -Double.pi / 2 { ang += 2 * .pi }
                if let s = segs.first(where: { r >= $0.r0 && r <= $0.r1 && ang >= $0.a0 && ang <= $0.a1 }) { onSelect(s.node) }
                else if r < side * 0.2, let p = node.parent { onSelect(p) }
            })
            .help("点击扇区进入文件夹，点击中心返回上一级")
        }
    }
}
