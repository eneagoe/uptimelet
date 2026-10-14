import AppKit
import XCTest
import UptimeCore
@testable import Uptimelet

final class StatusItemIconTests: XCTestCase {
    @MainActor
    func testAppearanceNotificationsTriggeredByDrawingDoNotLoop() {
        var assignments = 0
        var renderer: StatusItemIconRenderer!
        renderer = StatusItemIconRenderer { image, _, _ in
            assignments += 1
            // Simulate AppKit notifying effectiveAppearance while assigning/drawing.
            // Cap recursion so a regression fails instead of overflowing the stack.
            if assignments < 10 { renderer.update(status: .healthy, dark: false) }
            XCTAssertTrue(image.representations.allSatisfy { $0 is NSBitmapImageRep })
        }
        renderer.update(status: .healthy, dark: false)
        for _ in 0..<200 { renderer.update(status: .healthy, dark: false) }
        XCTAssertEqual(assignments, 1)
    }

    @MainActor
    func testStatusAndThemeTransitionsUpdateImageAndAccessibleLabels() {
        var images: [NSImage] = []
        var labels: [String] = []
        var tooltips: [String] = []
        let renderer = StatusItemIconRenderer { image, tooltip, label in
            images.append(image)
            tooltips.append(tooltip)
            labels.append(label)
        }
        renderer.update(status: .healthy, dark: false)
        renderer.update(status: .healthy, dark: true)
        renderer.update(status: .down, dark: true)
        renderer.update(status: .down, dark: true)
        renderer.update(status: .recovered, dark: true)
        renderer.update(status: .unknown, dark: true)
        renderer.update(status: .healthy, dark: false)
        XCTAssertEqual(images.count, 6)
        XCTAssertTrue(images[0] === images[5])
        XCTAssertFalse(images[0] === images[1])
        XCTAssertEqual(labels[2], "Uptimelet: \(OverallStatus.down.title)")
        XCTAssertEqual(tooltips[3], "Uptimelet · \(OverallStatus.recovered.title)")
    }

    @MainActor
    func testCachedIconsHaveCorrectStandardAndRetinaRepresentations() {
        for state: BeaconIcon.State in [.healthy, .recovered, .down, .unknown, .paused] {
            for dark in [false, true] {
                for size: CGFloat in [20, 52] {
                    let image = BeaconIcon.image(for: state, size: size, dark: dark)
                    XCTAssertTrue(image === BeaconIcon.image(for: state, size: size, dark: dark))
                    XCTAssertEqual(image.size, NSSize(width: size, height: size))
                    XCTAssertEqual(image.representations.count, 2)
                    XCTAssertEqual(image.representations.map(\.pixelsWide).sorted(), [Int(size), Int(size * 2)])
                    XCTAssertTrue(image.representations.allSatisfy { $0 is NSBitmapImageRep && $0.size == image.size })
                }
            }
        }
    }
}
