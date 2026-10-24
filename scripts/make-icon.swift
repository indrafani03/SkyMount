// Draws the SkyMount app icon (cloud mounted as a drive) and writes Resources/AppIcon.icns.
// Run from the package root: swift scripts/make-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "Resources")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt tile centred on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x1E6FD9))
    ctx.fillPath()
    ctx.restoreGState()

    // One blue hue, lighter at the top: the light direction every macOS icon uses.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [rgb(0x5BB8F5), rgb(0x1660C9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let white = CGColor(gray: 1, alpha: 1)

    // Cloud: three circles on a flat-bottomed base.
    let cloud = CGMutablePath()
    cloud.addEllipse(in: CGRect(x: 262, y: 560, width: 210, height: 210))
    cloud.addEllipse(in: CGRect(x: 380, y: 610, width: 280, height: 280))
    cloud.addEllipse(in: CGRect(x: 560, y: 560, width: 210, height: 210))
    cloud.addRect(CGRect(x: 367, y: 560, width: 298, height: 150))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.18))
    ctx.addPath(cloud)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.restoreGState()

    // Link from cloud to drive.
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: 494, y: 440, width: 36, height: 130))

    // Drive body with a slot and an activity light.
    let drive = CGRect(x: 262, y: 250, width: 500, height: 200)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.18))
    ctx.addPath(CGPath(roundedRect: drive, cornerWidth: 48, cornerHeight: 48, transform: nil))
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: CGRect(x: 312, y: 330, width: 260, height: 40),
                       cornerWidth: 20, cornerHeight: 20, transform: nil))
    ctx.setFillColor(rgb(0x1660C9))
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: 652, y: 320, width: 60, height: 60))

    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
exit(p.terminationStatus)
