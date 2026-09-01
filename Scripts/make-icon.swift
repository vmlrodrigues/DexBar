// Generates dist/AppIcon.iconset. Convert it with:
// iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns

import AppKit

func makeIcon(_ size: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let padding = size * 0.09
    let tile = CGRect(x: padding, y: padding, width: size - padding * 2, height: size - padding * 2)
    let tilePath = CGPath(
        roundedRect: tile,
        cornerWidth: size * 0.19,
        cornerHeight: size * 0.19,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.018),
        blur: size * 0.04,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(srgbRed: 0.34, green: 0.68, blue: 1.0, alpha: 1).cgColor,
            NSColor(srgbRed: 0.08, green: 0.36, blue: 0.93, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: []
    )

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: size * 0.49, weight: .semibold)
    let attributed = NSAttributedString(
        string: "D",
        attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
    )
    let textSize = attributed.size()
    let textRect = CGRect(
        x: tile.midX - textSize.width / 2,
        y: tile.midY - textSize.height / 2 - size * 0.006,
        width: textSize.width,
        height: textSize.height
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    attributed.draw(in: textRect)
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()

    context.addPath(tilePath)
    context.setLineWidth(max(1, size * 0.003))
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    context.strokePath()
    return context.makeImage()!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("dist/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in variants {
    let pixels = base * scale
    let representation = NSBitmapImageRep(cgImage: makeIcon(CGFloat(pixels)))
    representation.size = NSSize(width: base, height: base)
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let data = representation.representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
}
print("wrote \(variants.count) icon images")
