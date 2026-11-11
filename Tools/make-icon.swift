// Renders Resources/AppIcon.icns (and Resources/AppIcon-1024.png): the CueVideo mark.
// The Cue family's three bars as the body of a video camera, with the lens wedge beside them.
// Same tile, colours and bar shape as the other Cue apps' icon scripts (CueLights, CueTracks);
// coordinates in their 648 point artwork tile (y down).
// Run: swift Tools/make-icon.swift [repo root]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let midnight = NSColor(srgbRed: 0x09/255, green: 0x10/255, blue: 0x18/255, alpha: 1)
let edge = NSColor(srgbRed: 0x4B/255, green: 0x50/255, blue: 0x55/255, alpha: 1)
let light = NSColor(srgbRed: 0xDA/255, green: 0xED/255, blue: 0xFA/255, alpha: 1)
let mid = NSColor(srgbRed: 0x5C/255, green: 0xA2/255, blue: 0xD9/255, alpha: 1)
let dark = NSColor(srgbRed: 0x2F/255, green: 0x5F/255, blue: 0x87/255, alpha: 1)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = size / 1024
    // Artwork tile 12...636 maps to the macOS icon tile 100...924 (of 1024).
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (100 + (x - 12) * 824 / 624) * k, y: (1024 - (100 + (y - 12) * 824 / 624)) * k) }
    func L(_ v: CGFloat) -> CGFloat { v * 824 / 624 * k }
    let lean: CGFloat = 0.2   // the brand's slant: how far an edge leans per unit of height
    // A Cue bar: round at the left, the brand's slant down the right (top corner further right).
    func bar(_ x0: CGFloat, _ x1: CGFloat, _ top: CGFloat, _ bottom: CGFloat, _ c: NSColor) {
        let h = bottom - top, r = h / 2
        let p = NSBezierPath()
        p.move(to: P(x0 + r, top)); p.line(to: P(x1, top)); p.line(to: P(x1 - h * lean, bottom)); p.line(to: P(x0 + r, bottom))
        p.appendArc(withCenter: P(x0 + r, top + r), radius: L(r), startAngle: 270, endAngle: 90, clockwise: true)
        p.close(); c.setFill(); p.fill()
    }
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k), xRadius: 180 * k, yRadius: 180 * k)
    midnight.setFill(); tile.fill()
    edge.setStroke(); tile.lineWidth = max(1, 5 * k); tile.stroke()

    // The camera body: three bars stacked, lightest on top. Each starts a little further
    // left than the one above, so their slanted ends line up as one edge.
    let h: CGFloat = 84, gap: CGFloat = 14, top: CGFloat = 324 - (3 * h + 2 * gap) / 2
    let right: CGFloat = 410
    for (i, c) in [light, mid, dark].enumerated() {
        let y = top + CGFloat(i) * (h + gap)
        bar(104, right - (y - top) * lean, y, y + h, c)
    }
    // The lens: a wedge opening to the right, its edges leaning with the bars.
    let bodyBottom = top + 3 * h + 2 * gap
    let y0 = top + 70, y1 = bodyBottom - 70          // where it meets the body
    let y2 = top + 6, y3 = bodyBottom - 6            // its open end
    let x0 = right + 28, x1: CGFloat = 548
    let w = NSBezierPath()
    w.move(to: P(x0 - (y0 - top) * lean, y0)); w.line(to: P(x1 - (y2 - top) * lean, y2))
    w.line(to: P(x1 - (y3 - top) * lean, y3)); w.line(to: P(x0 - (y1 - top) * lean, y1)); w.close()
    w.lineJoinStyle = .round; w.lineWidth = L(18)
    light.setFill(); light.setStroke(); w.fill(); w.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let res = root.appendingPathComponent("Resources")
try! draw(1024).representation(using: .png, properties: [:])!.write(to: res.appendingPathComponent("AppIcon-1024.png"))
let set = res.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.launchPath = "/usr/bin/iconutil"; p.arguments = ["-c", "icns", set.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
p.launch(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("wrote \(res.path)/AppIcon.icns")
