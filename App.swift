import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        // 自动化测试：不出现在程序坞、不激活、不抢用户的焦点
        if TestEnv.active { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FileButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var app = AppState()
    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        TestEnv.setup(args)
        if let i = args.firstIndex(of: "--bench") { exit(Bench.run(URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "/tmp/fb-perf"))) }
        ThumbCache.start()
    }
    var body: some Scene {
        Window("文件管家", id: "main") {
            ContentView().environmentObject(app).frame(minWidth: 900, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("授予完全磁盘访问权限…") { app.showFDA = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("新建标签页") { app.newTab() }.keyboardShortcut("t")
                Button("新建文件夹") { app.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("用所选项目新建文件夹") { app.newFolderWithItems(app.activeTab.selectedURLs) }.keyboardShortcut("n", modifiers: [.command, .control])
                Divider()
                Button("关闭标签页") { app.closeTab() }.keyboardShortcut("w")
            }
            CommandGroup(after: .undoRedo) {
                Button("撤销上一步文件操作") { app.undo() }.keyboardShortcut("z", modifiers: [.command, .option])
            }
            CommandMenu("操作") {
                Button("打开所选") { app.activeController.openSelection() }.keyboardShortcut(.downArrow)
                Button("快速查看") { app.activeController.quickLook() }.keyboardShortcut("y")
                Button("重命名…") { app.activeController.renameSelection() }
                Button("复制") { app.duplicate(app.activeTab.selectedURLs) }
                Button("制作替身") { app.makeAlias(app.activeTab.selectedURLs) }.keyboardShortcut("a", modifiers: [.command, .control])
                Button("压缩") { app.zip(app.activeTab.selectedURLs) }
                Button("移到废纸篓") { app.trash(app.activeTab.selectedURLs) }
                Divider()
                Button("拷贝到另一栏") { app.copyToOther(move: false) }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)), modifiers: [])
                Button("移动到另一栏") { app.copyToOther(move: true) }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(UInt32(NSF6FunctionKey))!)), modifiers: [])
                Divider()
                Button("空间分析") { app.sizeReq = SizeReq(url: app.activeTab.path) }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("把当前文件夹加入书签") { app.addBookmark() }.keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("前往") {
                Button("后退") { app.activeTab.goBack() }.keyboardShortcut("[")
                Button("前进") { app.activeTab.goForward() }.keyboardShortcut("]")
                Button("上级文件夹") { app.activeTab.goUp() }.keyboardShortcut(.upArrow)
                Divider()
                Button("输入路径…") { app.editingPane = app.active }.keyboardShortcut("l")
                Button("前往文件夹…") { app.editingPane = app.active }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("个人") { app.go(FileManager.default.homeDirectoryForCurrentUser) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("桌面") { app.go(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")) }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("下载") { app.go(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("应用程序") { app.go(URL(fileURLWithPath: "/Applications")) }.keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("切换左右栏") { app.switchPane() }
            }
            CommandGroup(before: .toolbar) {
                ForEach(Array(ViewMode.allCases.enumerated()), id: \.offset) { i, m in
                    Button("\(m.title)显示方式") { app.setViewMode(m) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("搜索") { app.searchFocus += 1 }.keyboardShortcut("f")
                Button(app.showPreview ? "隐藏预览" : "显示预览") { app.showPreview.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button(app.showPathBar ? "隐藏路径栏" : "显示路径栏") { app.showPathBar.toggle() }.keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button(app.dual ? "切换为单栏" : "切换为双栏") { app.dual.toggle() }.keyboardShortcut("u", modifiers: [.command, .option])
                Button(app.showHidden ? "不显示隐藏文件" : "显示隐藏文件") { app.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button(app.showPreview ? "隐藏信息面板" : "显示信息面板") { app.showPreview.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }
    }
}
