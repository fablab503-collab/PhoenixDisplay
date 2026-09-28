import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024

func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render() -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icon grid: art occupies the middle ~80% of the canvas.
    let inset: CGFloat = S * 0.098
    let plate = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
    let radius = plate.width * 0.225

    // Drop shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.035,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(squircle(plate, radius))
    ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient: deep indigo to warm ember, a nod to the name.
    ctx.saveGState()
    ctx.addPath(squircle(plate, radius))
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.16, green: 0.20, blue: 0.45, alpha: 1),
        CGColor(red: 0.30, green: 0.18, blue: 0.48, alpha: 1),
        CGColor(red: 0.62, green: 0.22, blue: 0.36, alpha: 1),
    ] as CFArray, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

    // Glass sheen across the top third.
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY + plate.height*0.05),
                           options: [])
    ctx.restoreGState()

    // Two panels: the Mac, and the screen it extends onto.
    let pw = plate.width * 0.46
    let ph = pw * 0.64
    let back  = CGRect(x: plate.midX - pw*0.92, y: plate.midY - ph*0.28, width: pw, height: ph)
    let front = CGRect(x: plate.midX - pw*0.06, y: plate.midY - ph*0.72, width: pw, height: ph)
    let pr = pw * 0.085

    // Back panel — translucent, the source screen.
    ctx.saveGState()
    ctx.addPath(squircle(back, pr))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.fillPath()
    ctx.addPath(squircle(back, pr))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    ctx.setLineWidth(S * 0.009)
    ctx.strokePath()
    ctx.restoreGState()

    // Front panel — solid, the new desktop.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.008), blur: S*0.022,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
    ctx.addPath(squircle(front, pr))
    ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // A single accent bar inside the front panel: content has arrived.
    let bar = CGRect(x: front.minX + front.width*0.12,
                     y: front.minY + front.height*0.60,
                     width: front.width*0.52, height: front.height*0.10)
    ctx.addPath(squircle(bar, bar.height/2))
    ctx.setFillColor(CGColor(red: 0.62, green: 0.22, blue: 0.36, alpha: 1))
    ctx.fillPath()
    let bar2 = CGRect(x: front.minX + front.width*0.12,
                      y: front.minY + front.height*0.40,
                      width: front.width*0.34, height: front.height*0.10)
    ctx.addPath(squircle(bar2, bar2.height/2))
    ctx.setFillColor(CGColor(red: 0.16, green: 0.20, blue: 0.45, alpha: 0.45))
    ctx.fillPath()

    return ctx.makeImage()!
}


// Build the .icns by hand: sips and iconutil both need a temp directory this
// sandbox won't give them, and the format is simple enough to emit directly.
func png(_ img: CGImage, _ size: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let scaled = c.makeImage()!
    let data = NSMutableData()
    let d = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, scaled, nil)
    CGImageDestinationFinalize(d)
    return data as Data
}

func be32(_ v: UInt32) -> Data {
    var b = v.bigEndian
    return withUnsafeBytes(of: &b) { Data($0) }
}

let master = render()
// type -> pixel size
let entries: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]

var body = Data()
for (type, size) in entries {
    let data = png(master, size)
    body.append(type.data(using: .ascii)!)
    body.append(be32(UInt32(data.count + 8)))
    body.append(data)
}
var icns = Data()
icns.append("icns".data(using: .ascii)!)
icns.append(be32(UInt32(body.count + 8)))
icns.append(body)
try! icns.write(to: URL(fileURLWithPath: out))

// Also drop a 1024 PNG next to it for the README / store use.
let pngURL = URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png")
try! png(master, 1024).write(to: pngURL)
print("wrote \(out) (\(icns.count) bytes) and \(pngURL.lastPathComponent)")
