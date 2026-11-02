// Renders the Seamline app icon as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift out.png
//
// Two Macs side by side, a desktop display and a laptop, joined by one bright line:
// the pointer's path across the seam, ending in the cursor on the second screen.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// MARK: Background: the macOS icon grid's 824 pt squircle with a soft drop shadow.

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0.07, 0.09, 0.20)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.20, 0.27, 0.62), color(0.09, 0.11, 0.30), color(0.04, 0.05, 0.14)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A cool glow behind the seam, where the pointer crosses.
ctx.drawRadialGradient(gradient([color(0.30, 0.72, 1, 0.38), color(0.30, 0.72, 1, 0)]),
                       startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 540), endRadius: 360, options: [])
ctx.restoreGState()

// MARK: Two Macs

let frameColor = color(0.93, 0.95, 1.0)
func screen(_ r: CGRect) {
    // Bezel, then the lit glass inside it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.45))
    ctx.addPath(rounded(r, 26)); ctx.setFillColor(frameColor); ctx.fillPath()
    ctx.restoreGState()
    let glass = r.insetBy(dx: 16, dy: 16)
    ctx.saveGState()
    ctx.addPath(rounded(glass, 12)); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0.16, 0.34, 0.86), color(0.10, 0.17, 0.48)]),
                           start: CGPoint(x: glass.minX, y: glass.maxY), end: CGPoint(x: glass.maxX, y: glass.minY), options: [])
    ctx.restoreGState()
}

// Desktop display on the left, on a stand.
let display = CGRect(x: 168, y: 410, width: 330, height: 236)
ctx.saveGState()
ctx.setFillColor(color(0.78, 0.81, 0.90))
let neck = CGMutablePath()
neck.move(to: CGPoint(x: display.midX - 34, y: display.minY + 2))
neck.addLine(to: CGPoint(x: display.midX + 34, y: display.minY + 2))
neck.addLine(to: CGPoint(x: display.midX + 46, y: 336))
neck.addLine(to: CGPoint(x: display.midX - 46, y: 336))
neck.closeSubpath()
ctx.addPath(neck); ctx.fillPath()
ctx.addPath(rounded(CGRect(x: display.midX - 92, y: 318, width: 184, height: 24), 12)); ctx.fillPath()
ctx.restoreGState()
screen(display)

// Laptop on the right: lid and base.
let lid = CGRect(x: 546, y: 382, width: 300, height: 214)
screen(lid)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.4))
let base = CGMutablePath()
base.move(to: CGPoint(x: lid.minX - 34, y: lid.minY - 4))
base.addLine(to: CGPoint(x: lid.maxX + 34, y: lid.minY - 4))
base.addLine(to: CGPoint(x: lid.maxX + 24, y: lid.minY - 30))
base.addLine(to: CGPoint(x: lid.minX - 24, y: lid.minY - 30))
base.closeSubpath()
ctx.addPath(base); ctx.setFillColor(color(0.80, 0.83, 0.92)); ctx.fillPath()
ctx.restoreGState()

// MARK: The seam line: the pointer's path from one screen to the other

let start = CGPoint(x: 236, y: 498)
let end = CGPoint(x: 676, y: 500)
let path = CGMutablePath()
path.move(to: start)
path.addCurve(to: end, control1: CGPoint(x: 380, y: 640), control2: CGPoint(x: 540, y: 370))

// Glow, then a bright core in a cyan-to-white gradient along the stroke.
ctx.saveGState()
ctx.addPath(path)
ctx.setLineWidth(42); ctx.setLineCap(.round)
ctx.setStrokeColor(color(0.35, 0.85, 1, 0.28)); ctx.strokePath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.setLineWidth(20); ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.25, 0.80, 1), color(0.62, 0.92, 1), color(1, 1, 1)]),
                       start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Where the line leaves the first Mac.
ctx.setFillColor(color(0.25, 0.80, 1))
ctx.fillEllipse(in: CGRect(x: start.x - 20, y: start.y - 20, width: 40, height: 40))

// MARK: The cursor, arriving on the laptop

let cursor = CGMutablePath()
// The arrow tip sits where the line ends, fully inside the laptop's screen.
let tip = CGPoint(x: end.x, y: end.y + 44)
let k: CGFloat = 0.74
let points: [CGPoint] = [(0, 0), (0, -150), (36, -114), (62, -170), (88, -158), (62, -104), (110, -104)]
    .map { CGPoint(x: tip.x + $0.0 * k, y: tip.y + $0.1 * k) }
cursor.addLines(between: points)
cursor.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.5))
ctx.addPath(cursor)
ctx.setLineJoin(.round)
ctx.setLineWidth(12)
ctx.setStrokeColor(color(0.06, 0.08, 0.18))
ctx.setFillColor(color(1, 1, 1))
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()
ctx.addPath(cursor); ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
