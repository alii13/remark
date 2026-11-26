// Renders the Remark app icon (1024x1024): dark squircle, warm radial ground,
// a soft amber glow, and the two amber quote strokes. Saves to the path in argv[1].
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/remark-icon.png"
let S: CGFloat = 1024

let amber = NSColor(red: 0.913, green: 0.663, blue: 0.302, alpha: 1)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// squircle mask (macOS icons ~ 22.4% corner radius)
let inset: CGFloat = 0
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let corner = (S - inset*2) * 0.224
let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(squircle); ctx.clip()

// warm dark radial ground
let cs = CGColorSpaceCreateDeviceRGB()
let ground = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.137, green: 0.122, blue: 0.090, alpha: 1),
    CGColor(red: 0.059, green: 0.059, blue: 0.063, alpha: 1)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(ground, startCenter: CGPoint(x: S*0.5, y: S*0.62), startRadius: 0,
    endCenter: CGPoint(x: S*0.5, y: S*0.62), endRadius: S*0.75, options: [])

// soft amber glow behind the mark
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.913, green: 0.663, blue: 0.302, alpha: 0.33),
    CGColor(red: 0.913, green: 0.663, blue: 0.302, alpha: 0)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S*0.5, y: S*0.54), startRadius: 0,
    endCenter: CGPoint(x: S*0.5, y: S*0.54), endRadius: S*0.34, options: [])

// the two quote strokes (CoreGraphics y is up)
func quote(_ x: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: S*0.66))
    p.addCurve(to: CGPoint(x: x - S*0.055, y: S*0.37),
               control1: CGPoint(x: x - S*0.085, y: S*0.58),
               control2: CGPoint(x: x - S*0.090, y: S*0.46))
    ctx.addPath(p)
}
ctx.setStrokeColor(amber.cgColor)
ctx.setLineWidth(S*0.085)
ctx.setLineCap(.round)
quote(S*0.435)   // left quote
quote(S*0.615)   // right quote
ctx.strokePath()

// subtle top inner highlight for depth
ctx.addPath(squircle)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
