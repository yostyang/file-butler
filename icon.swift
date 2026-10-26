import SwiftUI
let a1 = Color(red: 0.42, green: 0.36, blue: 0.98), a2 = Color(red: 0.18, green: 0.70, blue: 0.96)
struct Pane: View { let tint: Color; var body: some View {
  ZStack { RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color.white.opacity(0.95))
    Image(systemName: "folder.fill").font(.system(size: 170)).foregroundStyle(tint) }.frame(width: 270, height: 400) } }
struct IconView: View { var body: some View { ZStack {
  RoundedRectangle(cornerRadius: 230, style: .continuous).fill(LinearGradient(colors: [a1, a2], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 824, height: 824)
  RoundedRectangle(cornerRadius: 70, style: .continuous).fill(Color.white.opacity(0.22)).frame(width: 640, height: 500)
  HStack(spacing: 40) { Pane(tint: a1); Pane(tint: a2) }
  Circle().fill(Color.white).frame(width: 120, height: 120).shadow(radius: 10)
  Image(systemName: "arrow.left.arrow.right").font(.system(size: 60, weight: .bold)).foregroundStyle(a1)
}.frame(width: 1024, height: 1024) } }
@MainActor func run() { let r = ImageRenderer(content: IconView()); r.scale = 1
  if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) { try! png.write(to: URL(fileURLWithPath: "icon.png")) } }
MainActor.assumeIsolated { run() }
