import AppKit
import SwiftUI

// MARK: - 访达式进度窗口：操作超过 0.75 秒才出现；多个操作叠在同一个窗口里；每项可停止

/// 正在进行 / 排队的操作列表（只在开始和结束时变化；进度数字由进度窗口每 0.1 秒自己读）
final class OpCenter: ObservableObject {
    @Published private(set) var ops: [OpProgress] = []
    /// 测试用：出现前的延迟（访达不会为瞬间完成的操作闪一下窗口）
    static var showDelay: TimeInterval = 0.75
    private var panel: NSPanel?
    private var timer: Timer?
    func add(_ p: OpProgress) {
        ops.append(p)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
    func remove(_ p: OpProgress) {
        ops.removeAll { $0 === p }
        if ops.isEmpty { timer?.invalidate(); timer = nil; panel?.orderOut(nil) }
    }
    var isPanelVisible: Bool { panel?.isVisible == true }
    var panelWindow: NSPanel? { panel }
    private func tick() {
        guard let oldest = ops.first, !isPanelVisible else { return }
        if Date().timeIntervalSince(oldest.started) >= OpCenter.showDelay { show() }
    }
    private(set) var shownCount = 0
    func show() {
        shownCount += 1
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 90),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "进度"
            p.isFloatingPanel = false; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.becomesKeyOnlyIfNeeded = true
            let host = NSHostingView(rootView: ProgressList(center: self))
            p.contentView = host
            p.center()
            if let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                let f = w.frame; p.setFrameTopLeftPoint(NSPoint(x: f.midX - 230, y: f.maxY - 80))
            }
            panel = p
        }
        if let host = panel?.contentView { let h = max(60, host.fittingSize.height); panel?.setContentSize(NSSize(width: 460, height: h)) }
        panel?.title = ops.first.map { Self.windowTitle($0.kind) } ?? "进度"
        panel?.orderFront(nil)
    }
    static func windowTitle(_ k: OpKind) -> String {
        switch k { case .copy: return "拷贝"; case .move: return "移动"; case .trash: return "移到废纸篓"; case .other: return "进度" }
    }
    /// 「正在将“a.mov”拷贝到“备份”」/「正在将 3 个项目拷贝到“备份”」
    static func title(_ p: OpProgress) -> String {
        let what = p.total == 1 ? "“\(p.firstName)”" : " \(p.total) 个项目"
        switch p.kind {
        case .copy: return "正在将\(what)拷贝到“\(p.destName)”"
        case .move: return "正在将\(what)移动到“\(p.destName)”"
        case .trash: return "正在将\(what)移到废纸篓"
        case .other: return "正在\(p.verb)\(what)"
        }
    }
    /// 「已拷贝 1.2 GB，共 3.4 GB — 约剩 10 秒」/「已移动 3 个项目，共 10 个」
    static func detail(_ p: OpProgress, now: Date = Date()) -> String {
        if p.isCancelled { return "正在停止…" }
        if !p.isRunning { return "等待中…" }
        let el = now.timeIntervalSince(p.started)
        var s: String
        let bt = p.bytesTotal, bd = p.bytesDone
        if bt > 0 {
            s = "已\(p.kind == .move ? "移动" : "拷贝") \(fmtBytes(bd))，共 \(fmtBytes(bt))"
            if bd > 0 && el > 1.5 {
                let left = Double(bt - bd) / (Double(bd) / el)
                s += " — " + Self.eta(left)
            }
        } else if bt < 0 && (p.kind == .copy) && p.done == 0 {
            s = "正在准备…"
        } else {
            let verb = p.kind == .trash ? "已移到废纸篓" : p.kind == .move ? "已移动" : "已完成"
            s = "\(verb) \(p.done) 个项目，共 \(p.total) 个"
        }
        // 看门狗：长时间没有任何进展时说清楚，而不是让人以为卡死
        let idle = now.timeIntervalSince(p.lastTick)   // 看门狗
        if idle > 15 && el > 15 { s += "（已 \(Int(idle)) 秒没有进展，可能在等待磁盘或网络响应）" }
        return s
    }
    static func eta(_ sec: Double) -> String {
        if !sec.isFinite || sec < 0 { return "正在估算剩余时间…" }
        if sec < 5 { return "马上就好" }
        if sec < 60 { return "约剩 \(Int(sec.rounded())) 秒" }
        if sec < 3600 { return "约剩 \(Int((sec / 60).rounded())) 分钟" }
        return String(format: "约剩 %.1f 小时", sec / 3600)
    }
    static func fraction(_ p: OpProgress) -> Double? {
        let bt = p.bytesTotal
        if bt > 0 { return min(1, Double(p.bytesDone) / Double(bt)) }
        if bt < 0 && p.kind == .copy && p.done == 0 { return nil }   // 不确定进度条
        return p.total > 0 ? min(1, Double(p.done) / Double(p.total)) : nil
    }
}

struct ProgressList: View {
    @ObservedObject var center: OpCenter
    var body: some View {
        VStack(spacing: 0) {
            ForEach(center.ops) { p in
                if p !== center.ops.first { Divider() }
                ProgressRow(p: p)
            }
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProgressRow: View {
    let p: OpProgress
    var body: some View {
        // 每 0.1 秒读一次后台进度（10Hz，不会拖慢拷贝或主线程）
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(for: p.kind == .trash ? .item : .folder))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(OpCenter.title(p)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let f = OpCenter.fraction(p) { ProgressView(value: f).progressViewStyle(.linear).controlSize(.small) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                    Text(OpCenter.detail(p, now: ctx.date)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Button { p.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("停止").accessibilityLabel("停止")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

extension OpProgress: Identifiable {}
