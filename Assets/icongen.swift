import AppKit

// 图标生成器：OPPO Pods Manager macOS 图标（1024 起稿）
// 绿色渐变圆角方块 + 双耳机（官方产品图）+ 柔和投影

let assetsDir = "Assets"
let outPng = "Assets/AppIcon_1024.png"

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocusFlipped(false)
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// ---- 背景：圆角方块 + 绿色渐变 ----
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = 232
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(bg)
ctx.clip()

let bgColors = [
    CGColor(red: 0.13, green: 0.83, blue: 0.58, alpha: 1),   // 亮绿
    CGColor(red: 0.02, green: 0.52, blue: 0.36, alpha: 1),   // 深绿
] as CFArray
let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 60, y: 1000), end: CGPoint(x: 964, y: 24), options: [])

// 顶部柔光
let hlColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0),
] as CFArray
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hlColors, locations: [0, 1])!
ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 300, y: 850), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 850), endRadius: 640, options: [])

// ---- 背景装饰：大圆弧（充电盒轮廓暗示），低不透明度白色描边 ----
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
ctx.setLineWidth(26)
ctx.strokeEllipse(in: CGRect(x: 212, y: 152, width: 600, height: 600))
ctx.restoreGState()

// ---- 双耳机 ----
func drawBud(_ file: String, center: CGPoint, height: CGFloat, rotationDegrees: CGFloat) {
    guard let nsimg = NSImage(contentsOfFile: file),
          var cg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("missing \(file)")
    }
    let aspect = CGFloat(cg.width) / CGFloat(cg.height)
    let h = height
    let w = h * aspect

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotationDegrees * .pi / 180)
    ctx.translateBy(x: -w / 2, y: -h / 2)

    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46,
                  color: CGColor(red: 0, green: 0.22, blue: 0.15, alpha: 0.5))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.restoreGState()
}

// 左耳：略小、左倾；右耳：主位、右倾（视觉重心居中）
drawBud("\(assetsDir)/official_left.png",
        center: CGPoint(x: 396, y: 512), height: 580, rotationDegrees: -9)
drawBud("\(assetsDir)/official_right.png",
        center: CGPoint(x: 652, y: 462), height: 645, rotationDegrees: 8)

image.unlockFocus()

// ---- 导出 PNG ----
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
try! png.write(to: URL(fileURLWithPath: outPng))
print("written \(outPng)")
