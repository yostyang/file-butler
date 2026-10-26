import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

// MARK: 预览区：音视频和访达一样默认不播放，先显示封面帧 + 播放按钮，点按后才创建播放器
func isAVMedia(_ u: URL) -> Bool {
    guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
    return t.conforms(to: .audiovisualContent)
}
func isVideo(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension.lowercased())?.conforms(to: .movie) ?? false }
func isImageFile(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension.lowercased())?.conforms(to: .image) ?? false }

/// 给测试读取的播放状态
enum MediaPreviewState {
    static weak var player: AVPlayer?
    static var created = 0
}

final class MediaModel: ObservableObject {
    let url: URL
    @Published var poster: NSImage?
    @Published var player: AVPlayer?
    init(url: URL) { self.url = url }
    func loadPoster() {
        guard poster == nil else { return }
        let u = url
        if !isVideo(u) { poster = NSWorkspace.shared.icon(forFile: u.path); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 800, height: 800)
            let cg = try? g.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil)
            DispatchQueue.main.async {
                if let cg = cg { self.poster = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                else { self.poster = NSWorkspace.shared.icon(forFile: u.path) }
            }
        }
    }
    func play() {
        let p = AVPlayer(url: url)
        player = p; MediaPreviewState.player = p; MediaPreviewState.created += 1
        p.play()
    }
    func stop() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }
    deinit { player?.pause() }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.player = player; v.controlsStyle = .inline; v.showsFullScreenToggleButton = true; return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause(); v.player = nil }
}

/// 播放按钮的位置标记（给界面测试找按钮用，不接收事件）
final class PlayButtonMarker: NSView { override func hitTest(_ p: NSPoint) -> NSView? { nil } }
enum PlayButtonRegistry { static weak var marker: PlayButtonMarker? }
struct PlayButtonMarkerView: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayButtonMarker { let v = PlayButtonMarker(); PlayButtonRegistry.marker = v; return v }
    func updateNSView(_ v: PlayButtonMarker, context: Context) { PlayButtonRegistry.marker = v }
}

struct MediaPreview: View {
    @StateObject var model: MediaModel
    init(url: URL) { _model = StateObject(wrappedValue: MediaModel(url: url)) }
    var body: some View {
        ZStack {
            if let p = model.player {
                PlayerView(player: p)
            } else {
                Color.black.opacity(isVideo(model.url) ? 0.04 : 0)
                if let img = model.poster { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(isVideo(model.url) ? 0 : 40) }
                Button { model.play() } label: {
                    ZStack {
                        Circle().fill(.ultraThinMaterial).frame(width: 54, height: 54)
                        Circle().fill(Color.black.opacity(0.35)).frame(width: 54, height: 54)
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).offset(x: 2)
                    }
                    .background(PlayButtonMarkerView())
                }
                .buttonStyle(.plain).help("播放")
                .accessibilityIdentifier("media-play")
            }
        }
        .onAppear { model.loadPoster() }
        .onDisappear { model.stop() }
    }
}

/// 预览区使用的内容：音视频用不自动播放的 MediaPreview，其他用快速查看
struct PreviewSurface: View {
    let url: URL
    var body: some View {
        if isAVMedia(url) { MediaPreview(url: url).id(url) } else { QLView(url: url) }
    }
}

// MARK: 访达式日期：2026年10月16日 星期五 14:57
let finderDateFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 EEEE HH:mm"; return f
}()
func finderDate(_ d: Date?) -> String { d.map { finderDateFmt.string(from: $0) } ?? "--" }
func finderDuration(_ secs: Double) -> String {
    let s = Int(secs.rounded())
    return s >= 3600 ? String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: 快速操作
enum QuickActions {
    static var lastTrashed: URL?
    /// 向左旋转图片（ImageIO 重新编码，保留格式）。原文件先移到废纸篓，可从废纸篓找回。
    static func rotateImageLeft(_ u: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let type = CGImageSourceGetType(src),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw FBError("无法读取图片。") }
        // 先按 EXIF 方向摆正
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FBError("无法旋转图片。") }
        // 逆时针 90°
        ctx.translateBy(x: 0, y: CGFloat(w)); ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw FBError("无法旋转图片。") }
        let tmp = u.deletingLastPathComponent().appendingPathComponent(".fb-rotate-\(UUID().uuidString).\(u.pathExtension)")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw FBError("无法写入图片。") }
        var p = props; p[kCGImagePropertyOrientation] = 1; p[kCGImagePropertyPixelWidth] = nil; p[kCGImagePropertyPixelHeight] = nil
        CGImageDestinationAddImage(dst, out, p as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { try? FileManager.default.removeItem(at: tmp); throw FBError("无法写入图片。") }
        return try swapIn(tmp, for: u)
    }
    /// 向左旋转视频：只改轨道的显示方向（不重新编码，和访达一样快、不损失画质）
    static func rotateVideoLeft(_ u: URL, done: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: u)
        let comp = AVMutableComposition()
        do {
            let dur = CMTimeRange(start: .zero, duration: asset.duration)
            for t in asset.tracks {
                guard let ct = comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try ct.insertTimeRange(dur, of: t, at: .zero)
                if t.mediaType == .video {
                    let n = t.naturalSize
                    // 逆时针 90°：(x, y) -> (y, -x)，再平移回正区域
                    let rot = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
                    let cur = t.preferredTransform
                    let r = CGRect(origin: .zero, size: n).applying(cur)
                    var tr = cur.concatenating(rot)
                    let r2 = r.applying(rot)
                    tr = tr.concatenating(CGAffineTransform(translationX: -r2.minX, y: -r2.minY))
                    ct.preferredTransform = tr
                }
            }
        } catch { done(.failure(error)); return }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { done(.failure(FBError("无法旋转视频。"))); return }
        let tmp = u.deletingLastPathComponent().appendingPathComponent(".fb-rotate-\(UUID().uuidString).\(u.pathExtension)")
        ex.outputURL = tmp
        ex.outputFileType = u.pathExtension.lowercased() == "mov" ? .mov : .mp4
        ex.exportAsynchronously {
            DispatchQueue.main.async {
                if ex.status == .completed { done(Result { try swapIn(tmp, for: u) }) }
                else { try? FileManager.default.removeItem(at: tmp); done(.failure(ex.error ?? FBError("无法旋转视频。"))) }
            }
        }
    }
    /// 新文件换到原位置；原文件移到废纸篓（不永久删除）
    static func swapIn(_ tmp: URL, for u: URL) throws -> URL {
        let fm = FileManager.default
        let dates = try? fm.attributesOfItem(atPath: u.path)
        var trashed: NSURL?
        try fm.trashItem(at: u, resultingItemURL: &trashed)
        lastTrashed = trashed as URL?
        try fm.moveItem(at: tmp, to: u)
        if let c = dates?[.creationDate] { try? fm.setAttributes([.creationDate: c], ofItemAtPath: u.path) }
        try? u.setTags(FileOps.readTags(u))
        return u
    }
}
extension URL { func setTags(_ t: [String]) throws { try FileOps.setTags(self, t) } }

// MARK: 访达式信息面板
struct FinderInfoView: View {
    @EnvironmentObject var app: AppState
    let item: FileItem
    @ObservedObject var tab: TabModel
    @State var more = false
    @State var tagPop = false
    @State var busy = false
    var body: some View {
        let m = mediaInfo(item.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.isEmpty ? "/" : item.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled).lineLimit(3)
                    Text(item.isFolderLike ? item.kind : "\(item.kind) - \(fmtBytes(item.size))").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("信息").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(more ? "更少内容" : "更多内容") { withAnimation(.easeOut(duration: 0.15)) { more.toggle() } }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                row("创建时间", finderDate(item.created))
                row("修改时间", finderDate(item.modified))
                if let d = m.dims { row("尺寸", d.replacingOccurrences(of: " × ", with: "×")) }
                if let s = m.seconds { row("持续时间", finderDuration(s)) }
                if more {
                    row("上次打开时间", finderDate((try? item.url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate))
                    if !item.isFolderLike { row("大小", "\(item.size.formatted()) 字节") }
                    row("位置", item.url.deletingLastPathComponent().path)
                    row("权限", permString(item.url))
                }
                Divider()
                Text("标签").font(.system(size: 13, weight: .semibold))
                if !item.tags.isEmpty {
                    FlowTags(tags: item.tags)
                }
                Button { tagPop = true } label: { Text("添加标签…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .popover(isPresented: $tagPop, arrowEdge: .leading) { TagPopover(tab: tab).environmentObject(app) }
                    .disabled(tab.selectedURLs.isEmpty)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        if !item.isFolderLike { Divider(); actions.padding(.vertical, 8) }
    }
    @ViewBuilder var actions: some View {
        HStack(spacing: 18) {
            Spacer()
            if isImageFile(item.url) || isVideo(item.url) {
                action("向左旋转", "rotate.left") { rotate() }
            }
            if isVideo(item.url) || (isAVMedia(item.url) && !isVideo(item.url)) {
                action("修剪", "timeline.selection") { trim() }
            }
            Menu {
                Button("打开") { NSWorkspace.shared.open(item.url) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("拷贝路径") { copyPaths([item.url]) }
                if isImageFile(item.url) { Button("用「预览」打开") { openWith("com.apple.Preview") } }
                if isAVMedia(item.url) { Button("用 QuickTime Player 打开") { openWith("com.apple.QuickTimePlayerX") } }
            } label: {
                VStack(spacing: 3) { Image(systemName: "ellipsis.circle").font(.system(size: 18)); Text("更多…").font(.system(size: 11)) }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
        }.disabled(busy)
    }
    func action(_ t: String, _ s: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { VStack(spacing: 3) { Image(systemName: s).font(.system(size: 18)); Text(t).font(.system(size: 11)) } }.buttonStyle(.plain)
    }
    func openWith(_ bid: String) {
        if let a = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { NSWorkspace.shared.open([item.url], withApplicationAt: a, configuration: .init()) { _, _ in } }
    }
    /// 访达的「修剪」是内置编辑器；这里交给 QuickTime Player 并直接进入修剪（⌘T）
    func trim() {
        guard let a = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") else { return }
        NSWorkspace.shared.open([item.url], withApplicationAt: a, configuration: .init()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let p = item.url.path.replacingOccurrences(of: "\"", with: "\\\"")
                NSAppleScript(source: "tell application \"QuickTime Player\" to trim (first document whose path is \"\(p)\")")?.executeAndReturnError(nil)
            }
        }
    }
    func rotate() {
        let u = item.url
        if isImageFile(u) {
            do { _ = try QuickActions.rotateImageLeft(u); ThumbCache.purgeImages(); app.reloadVisible() }
            catch { app.showError("无法旋转", error.localizedDescription) }
        } else {
            busy = true; app.busyText = "正在旋转视频…"
            QuickActions.rotateVideoLeft(u) { r in
                busy = false; app.busyText = nil; ThumbCache.purgeImages(); app.reloadVisible()
                if case .failure(let e) = r { app.showError("无法旋转", e.localizedDescription) }
            }
        }
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 8)
            Text(v.isEmpty ? "--" : v).multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.font(.system(size: 12))
    }
}
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { t in HStack(spacing: 5) { TagDotsView(tags: [t]); Text(t).font(.system(size: 12)) } }
        }
    }
}
