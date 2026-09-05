// Generates the source iconset and the packaged Resources/AppIcon.icns.

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

    // A geometric D whose bowl doubles as a usage gauge. Keeping the mark to one
    // continuous stroke and one endpoint makes it survive the 16 px icon variant.
    let leftX = tile.minX + tile.width * 0.31
    let curveX = tile.minX + tile.width * 0.50
    let outerX = tile.minX + tile.width * 0.73
    let bottomY = tile.minY + tile.height * 0.28
    let topY = tile.minY + tile.height * 0.72
    let lineWidth = size * 0.080

    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: leftX, y: bottomY))
    mark.addLine(to: CGPoint(x: leftX, y: topY))
    mark.addLine(to: CGPoint(x: curveX, y: topY))
    mark.addCurve(
        to: CGPoint(x: curveX, y: bottomY),
        control1: CGPoint(x: outerX, y: topY),
        control2: CGPoint(x: outerX, y: bottomY)
    )
    mark.closeSubpath()

    context.addPath(mark)
    context.setLineWidth(lineWidth)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.setStrokeColor(NSColor.white.cgColor)
    context.strokePath()

    // The endpoint is placed on the upper shoulder of the same Bezier curve. A
    // slim blue keyline keeps it legible where it overlaps the white gauge stroke.
    let endpoint = CGPoint(
        x: tile.minX + tile.width * 0.615,
        y: tile.minY + tile.height * 0.675
    )
    let endpointRadius = size * 0.035
    context.setFillColor(
        NSColor(srgbRed: 0.08, green: 0.36, blue: 0.93, alpha: 0.92).cgColor
    )
    context.fillEllipse(in: CGRect(
        x: endpoint.x - endpointRadius * 1.28,
        y: endpoint.y - endpointRadius * 1.28,
        width: endpointRadius * 2.56,
        height: endpointRadius * 2.56
    ))
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(
        x: endpoint.x - endpointRadius,
        y: endpoint.y - endpointRadius,
        width: endpointRadius * 2,
        height: endpointRadius * 2
    ))
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

// Modern ICNS files are a small big-endian container around PNG representations.
// Include both 1x and Retina semantic types even when two entries share a pixel size;
// Finder then selects the intended artwork instead of scaling an arbitrary variant.
let chunks: [(type: String, file: String)] = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

var body = Data()
for chunk in chunks {
    let type = Data(chunk.type.utf8)
    precondition(type.count == 4)
    let image = try Data(contentsOf: iconset.appendingPathComponent(chunk.file))
    body.append(type)
    appendBigEndian(UInt32(image.count + 8), to: &body)
    body.append(image)
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(body.count + 8), to: &icns)
icns.append(body)
let packagedIcon = root.appendingPathComponent("Resources/AppIcon.icns")
try icns.write(to: packagedIcon, options: .atomic)

print("wrote \(variants.count) icon images and \(packagedIcon.path)")
