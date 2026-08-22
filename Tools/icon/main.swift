// Draws Echo's app icon: concentric rings radiating from a single struck
// point, in the app's own palette. Regenerate with:
//   swiftc -O -o makeicon icon/main.swift && ./makeicon && \
//   iconutil -c icns Echo.iconset -o ../App/AppIcon.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let folder = "Echo.iconset"
try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

func draw(_ size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)

    // Rounded plate in the app's background color.
    let inset = s * 0.055
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let plated = CGPath(roundedRect: plate, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(plated)
    ctx.setFillColor(CGColor(red: 0.043, green: 0.051, blue: 0.063, alpha: 1))
    ctx.fillPath()
    ctx.addPath(plated)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.09))
    ctx.setLineWidth(max(0.5, s * 0.006))
    ctx.strokePath()

    // Rings, fading outward: one note, still arriving.
    let center = CGPoint(x: s / 2, y: s / 2)
    let rings: [(Double, Double, Double)] = [(0.13, 1.0, 0.055), (0.22, 0.52, 0.040),
                                             (0.31, 0.28, 0.032), (0.40, 0.14, 0.026)]
    for (radius, alpha, width) in rings {
        ctx.setStrokeColor(CGColor(red: 0.50, green: 0.85, blue: 0.79, alpha: alpha))
        ctx.setLineWidth(max(0.6, s * width))
        ctx.addArc(center: center, radius: s * radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(red: 0.50, green: 0.85, blue: 0.79, alpha: 1))
    ctx.addArc(center: center, radius: s * 0.045, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    return ctx.makeImage()
}

func write(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: "\(folder)/\(name)")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for size in sizes {
    guard let image = draw(size) else { continue }
    // iconutil wants both the 1x and the 2x name for each logical size.
    if [16, 32, 128, 256, 512].contains(size) { write(image, "icon_\(size)x\(size).png") }
    if [32, 64, 256, 512, 1024].contains(size) {
        write(image, "icon_\(size / 2)x\(size / 2)@2x.png")
    }
}
print("wrote \(folder)")
