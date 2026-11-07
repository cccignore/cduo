// 生成 Cduo 图标（1024px PNG）：圆角方块 + 两个交错的圆环（两个号错峰）
import Cocoa

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 80, y: 80, width: size - 160, height: size - 160)
let path = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor,
              NSColor(red: 0.62, green: 0.30, blue: 0.22, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.resetClip()
ctx.setLineWidth(70)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
ctx.strokeEllipse(in: CGRect(x: 230, y: 330, width: 340, height: 340))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
ctx.strokeEllipse(in: CGRect(x: 454, y: 330, width: 340, height: 340))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
