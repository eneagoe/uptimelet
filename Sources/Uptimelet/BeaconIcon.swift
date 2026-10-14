import AppKit

// Original vector artwork, shared by the live interface and app-icon renderer.
// Coordinates use a 20-point canvas with an upward y axis.
enum BeaconIcon {
    enum State: Equatable { case healthy, recovered, down, unknown, paused }

    static func color(for state: State) -> NSColor {
        switch state {
        case .healthy: return NSColor(srgbRed: 0.10, green: 0.70, blue: 0.43, alpha: 1)
        case .recovered: return NSColor(srgbRed: 0.84, green: 0.59, blue: 0.05, alpha: 1)
        case .down: return NSColor(srgbRed: 0.91, green: 0.23, blue: 0.30, alpha: 1)
        case .unknown, .paused: return .systemGray
        }
    }

    static func image(for state: State, size: CGFloat = 20, dark: Bool = false) -> NSImage {
        let foreground = dark ? NSColor.white : NSColor(srgbRed: 0.18, green: 0.22, blue: 0.27, alpha: 1)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, state: state, foreground: foreground)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(in rect: NSRect, state: State, foreground: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 20, yBy: rect.height / 20)
        transform.concat()

        let structure = (state == .unknown || state == .paused) ? NSColor.systemGray : foreground
        let light = color(for: state)
        structure.setFill()
        let tower = NSBezierPath()
        tower.move(to: NSPoint(x: 7, y: 3))
        tower.line(to: NSPoint(x: 8, y: 9))
        tower.line(to: NSPoint(x: 12, y: 9))
        tower.line(to: NSPoint(x: 13, y: 3))
        tower.close()
        tower.fill()
        NSBezierPath(roundedRect: NSRect(x: 5.7, y: 1.5, width: 8.6, height: 1.6), xRadius: 0.7, yRadius: 0.7).fill()
        let roof = NSBezierPath()
        roof.move(to: NSPoint(x: 6.2, y: 15.4))
        roof.line(to: NSPoint(x: 10, y: 18.3))
        roof.line(to: NSPoint(x: 13.8, y: 15.4))
        roof.close()
        roof.fill()

        let lens = NSBezierPath(roundedRect: NSRect(x: 6.6, y: 10, width: 6.8, height: 4.4), xRadius: 0.8, yRadius: 0.8)
        light.setFill()
        light.setStroke()
        if state == .unknown {
            lens.lineWidth = 1.1
            lens.stroke()
        } else {
            lens.fill()
        }

        func ray(_ points: [(CGFloat, CGFloat)], color: NSColor = light, width: CGFloat = 1.4) {
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
            path.stroke()
        }

        switch state {
        case .healthy:
            ray([(4.5, 12.2), (1.5, 12.2)])
            ray([(4.5, 14.7), (2.5, 16)])
            ray([(4.5, 9.7), (2.5, 8.4)])
            ray([(15.5, 12.2), (18.5, 12.2)])
            ray([(15.5, 14.7), (17.5, 16)])
            ray([(15.5, 9.7), (17.5, 8.4)])
        case .recovered:
            ray([(4.5, 12.2), (4, 12.2)])
            ray([(2, 12.2), (1.5, 12.2)])
            ray([(15.5, 12.2), (16, 12.2)])
            ray([(18, 12.2), (18.5, 12.2)])
            ray([(4.5, 14.7), (2.5, 16)])
            ray([(15.5, 14.7), (17.5, 16)])
        case .down:
            ray([(8.9, 11.1), (11.1, 13.3)], color: .white, width: 1.1)
            ray([(8.9, 13.3), (11.1, 11.1)], color: .white, width: 1.1)
        case .paused:
            ray([(9, 11), (9, 13.4)], color: .white, width: 1)
            ray([(11, 11), (11, 13.4)], color: .white, width: 1)
        case .unknown: break
        }
    }
}
