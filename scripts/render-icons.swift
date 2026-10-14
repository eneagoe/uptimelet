import AppKit

@main
enum RenderIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: render-icons ICONSET_DIR PREVIEW_DIR")
        }
        let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let previews = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                try writePNG(size: size * scale, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")) { canvas in
                    drawAppIcon(in: canvas)
                }
            }
        }
        try writePNG(size: 1024, to: previews.appendingPathComponent("app-icon.png"), drawing: drawAppIcon)
        try writePreview(to: previews.appendingPathComponent("beacon-states.png"))
        try writeICNS(iconset: iconset, to: iconset.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
    }

    // The ICNS container stores tagged PNG representations with big-endian lengths.
    // Write it directly to keep regeneration independent of image-conversion services.
    private static func writeICNS(iconset: URL, to output: URL) throws {
        let representations = [
            ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
            ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
            ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
            ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
        ]
        func chunk(_ type: String, payload: Data) -> Data {
            var data = Data(type.utf8)
            var length = UInt32(payload.count + 8).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(payload)
            return data
        }
        var contents = Data()
        for (type, file) in representations {
            contents.append(chunk(type, payload: try Data(contentsOf: iconset.appendingPathComponent(file))))
        }
        try chunk("icns", payload: contents).write(to: output)
        guard let decoded = NSImage(contentsOf: output), !decoded.representations.isEmpty else {
            fatalError("Generated app icon could not be decoded by AppKit")
        }
        print("AppKit decoded \(decoded.representations.count) app-icon representations.")
    }

    private static func writePNG(size: Int, to url: URL, drawing: (NSRect) -> Void) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        drawing(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func drawAppIcon(in canvas: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scaleX(by: canvas.width / 1024, yBy: canvas.height / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 186, yRadius: 186)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 35
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor(srgbRed: 0.05, green: 0.11, blue: 0.16, alpha: 1).setFill()
        tile.fill()
        NSShadow().set()
        NSGradient(starting: NSColor(srgbRed: 0.07, green: 0.14, blue: 0.21, alpha: 1),
                   ending: NSColor(srgbRed: 0.15, green: 0.28, blue: 0.34, alpha: 1))!.draw(in: tile, angle: 65)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        tile.lineWidth = 2
        tile.stroke()
        BeaconIcon.draw(in: NSRect(x: 210, y: 196, width: 604, height: 604), state: .healthy,
                        foreground: NSColor(srgbRed: 0.90, green: 0.97, blue: 0.98, alpha: 1))
    }

    private static func writePreview(to url: URL) throws {
        let size = NSSize(width: 1200, height: 510)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let states: [(BeaconIcon.State, String)] = [(.healthy, "Healthy"), (.recovered, "Recovered"), (.down, "Down"), (.unknown, "Waiting"), (.paused, "Paused")]
        NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSRect(x: 0, y: 255, width: 1200, height: 255).fill()
        NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 255).fill()
        for (index, pair) in states.enumerated() {
            let x = CGFloat(index) * 232 + 20
            for dark in [false, true] {
                let y: CGFloat = dark ? 0 : 255
                let foreground: NSColor = dark ? .white : NSColor(srgbRed: 0.18, green: 0.22, blue: 0.27, alpha: 1)
                BeaconIcon.draw(in: NSRect(x: x + 66, y: y + 111, width: 88, height: 88), state: pair.0, foreground: foreground)
                BeaconIcon.image(for: pair.0, dark: dark).draw(in: NSRect(x: x + 100, y: y + 74, width: 20, height: 20))
                (pair.1 as NSString).draw(at: NSPoint(x: x + 56, y: y + 35), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: foreground
                ])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
