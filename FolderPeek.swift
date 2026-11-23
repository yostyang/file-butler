import AppKit

/// 文件夹的快速查看（访达：选中文件夹按空格，显示大图标、名称、项目数、修改时间）。
/// 不激活、不抢焦点：空格 / Esc / 方向键仍由文件列表处理。
/// 只在后台数这一层有多少个项目（一次目录读取，不递归、不计算大小、没有计时器）；
/// 「空间分析…」按钮点了才开始计算大小。
final class FolderPeek: NSObject, NSWindowDelegate {
    static let shared = FolderPeek()
    private var panel: NSPanel?
    private(set) var url: URL?
    private weak var app: AppState?
    private var gen = 0
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let button = NSButton(title: "空间分析…", target: nil, action: nil)
    var isVisible: Bool { panel?.isVisible == true && url != nil }

    func show(_ u: URL, app: AppState) {
        self.app = app
        let p = panel ?? makePanel()
        url = u; gen += 1; let g = gen
        let it = makeItem(u)
        p.title = it.name
        icon.image = ThumbCache.icon(u)
        name.stringValue = it.name
        count.stringValue = "正在计算项目数…"
        size.stringValue = "大小：点「空间分析…」计算"
        date.stringValue = "修改时间：" + finderDate(it.modified)
        let hidden = app.showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            let n = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: hidden ? [] : [.skipsHiddenFiles]))?.count
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                self.count.stringValue = n.map { "\($0) 个项目" } ?? "无法读取内容"
            }
        }
        if !p.isVisible { place(p) }
        p.orderFront(nil)
    }
    func close() {
        gen += 1; url = nil
        panel?.orderOut(nil)
    }
    @objc func analyze() {
        guard let u = url, let app = app else { return }
        close()
        app.sizeReq = SizeReq(url: u)   // 只有点了按钮才计算大小
    }
    func windowWillClose(_ n: Notification) { gen += 1; url = nil }

    private func place(_ p: NSPanel) {
        #if FB_TESTING
        if TestEnv.active { p.setFrameOrigin(NSPoint(x: -6000, y: -6000)); return }   // 测试时不出现在屏幕上
        #endif
        if let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.toolbar != nil }) {
            let f = w.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        } else { p.center() }
    }
    private func makePanel() -> NSPanel {
        let W: CGFloat = 320, H: CGFloat = 330
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true; p.becomesKeyOnlyIfNeeded = true; p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false; p.delegate = self
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        icon.frame = NSRect(x: (W - 128) / 2, y: 20, width: 128, height: 128); icon.imageScaling = .scaleProportionallyUpOrDown
        var y: CGFloat = 160
        for f in [name, count, size, date] {
            f.font = f === name ? NSFont.boldSystemFont(ofSize: 14) : NSFont.systemFont(ofSize: 12)
            f.alignment = .center; f.lineBreakMode = .byTruncatingMiddle
            if f !== name { f.textColor = .secondaryLabelColor }
            f.frame = NSRect(x: 12, y: y, width: W - 24, height: f === name ? 20 : 17); y += f === name ? 26 : 21
            v.addSubview(f)
        }
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(analyze)
        button.frame = NSRect(x: (W - 140) / 2, y: y + 10, width: 140, height: 28)
        v.addSubview(icon); v.addSubview(button)
        p.contentView = v
        panel = p
        return p
    }
}
