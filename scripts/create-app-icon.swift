// Regenerate with: swift scripts/create-app-icon.swift Assets/Vidlib.png
import AppKit

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8,
  bytesPerRow: size * 4, space: space,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255,
    green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
  context.drawLinearGradient(
    CGGradient(
      colorsSpace: space, colors: colors as CFArray,
      locations: nil)!, start: from, end: to,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
let tile = CGPath(
  roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
  cornerWidth: 192, cornerHeight: 192, transform: nil)
context.saveGState()
context.setShadow(
  offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, alpha: 0.3))
context.addPath(tile)
context.setFillColor(color(0x101526))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(tile)
context.clip()
gradient(
  [color(0x252C48), color(0x0C1020)], from: CGPoint(x: 180, y: 960), to: CGPoint(x: 850, y: 64))
context.restoreGState()
context.addPath(tile)
context.setStrokeColor(color(0xFFFFFF, alpha: 0.12))
context.setLineWidth(2)
context.strokePath()

func ring(center: CGPoint, colors: [CGColor]) {
  let radius: CGFloat = 190
  let rect = CGRect(
    x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  context.saveGState()
  context.setBlendMode(.screen)
  context.addEllipse(in: rect)
  context.setLineWidth(48)
  context.replacePathWithStrokedPath()
  context.clip()
  gradient(
    colors, from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
  context.restoreGState()
}
ring(center: CGPoint(x: 512, y: 624), colors: [color(0x6CF9F5), color(0x2687F5)])
ring(center: CGPoint(x: 400, y: 430), colors: [color(0xFA8AE7), color(0xB557F2)])
ring(center: CGPoint(x: 624, y: 430), colors: [color(0xFFE58C), color(0xFF9260)])

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let data = bitmap.representation(using: .png, properties: [:])!
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/Vidlib.png"
try data.write(to: URL(fileURLWithPath: destination))
print("Created \(destination)")
