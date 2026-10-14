import AppKit
import Combine
import SwiftUI
#if canImport(UptimeCore)
import UptimeCore
#endif

@main
struct UptimeletMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var endpointWindows: [UUID: NSWindow] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var iconRenderer = StatusItemIconRenderer { [weak self] image, tooltip, accessibilityLabel in
        guard let button = self?.statusItem.button else { return }
        button.image = image
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabel)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 480)
        popover.contentViewController = NSHostingController(rootView: DashboardView(
            monitor: monitor, showSettings: { [weak self] in self?.showSettings() },
            showHistory: { [weak self] in self?.showHistory() },
            editEndpoint: { [weak self] endpoint in self?.showEndpointEditor(endpoint) }
        ))
        monitor.$state.combineLatest(monitor.$now)
            .map { state, now in state.overallStatus(at: now) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateIcon(status: status) }
            .store(in: &subscriptions)
        updateIcon()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    private func installMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Uptimelet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApplication.shared.mainMenu = menu
    }

    @objc private func openSettings() { showSettings() }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func updateIcon(status: OverallStatus? = nil) {
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        iconRenderer.update(status: status ?? monitor.overallStatus, dark: dark)
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Uptimelet Settings", size: NSSize(width: 680, height: 590))
        }
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView(
            monitor: monitor, close: { [weak self] in self?.settingsWindow?.close() },
            editEndpoint: { [weak self] endpoint in self?.showEndpointEditor(endpoint) }
        ))
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showHistory() {
        popover.performClose(nil)
        if historyWindow == nil {
            historyWindow = makeWindow(title: "Uptimelet History", size: NSSize(width: 780, height: 560))
            historyWindow?.contentViewController = NSHostingController(rootView: HistoryView(monitor: monitor))
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showEndpointEditor(_ endpoint: Endpoint) {
        popover.performClose(nil)
        if let window = endpointWindows[endpoint.id], window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = endpointWindows[endpoint.id] ?? makeWindow(
                title: endpoint.address.isEmpty ? "Add URL" : "Edit \(endpoint.displayName)",
                size: NSSize(width: 560, height: 640)
            )
            window.title = endpoint.address.isEmpty ? "Add URL" : "Edit \(endpoint.displayName)"
            window.contentViewController = NSHostingController(rootView: EndpointEditorView(
                monitor: monitor, endpoint: endpoint, close: { [weak window] in window?.close() }
            ))
            endpointWindows[endpoint.id] = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = size
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

@MainActor
final class StatusItemIconRenderer {
    private struct Presentation: Equatable {
        let status: OverallStatus
        let dark: Bool
    }

    private var lastPresentation: Presentation?
    private let display: (NSImage, String, String) -> Void

    init(display: @escaping (NSImage, String, String) -> Void) { self.display = display }

    func update(status: OverallStatus, dark: Bool) {
        let presentation = Presentation(status: status, dark: dark)
        guard presentation != lastPresentation else { return }
        // Set before assigning the image: AppKit's rendering may notify appearance
        // observers again. Identical or reentrant notifications must not redraw it.
        lastPresentation = presentation
        display(BeaconIcon.image(for: status.beaconState, dark: dark),
                "Uptimelet · \(status.title)", "Uptimelet: \(status.title)")
    }
}

extension OverallStatus {
    var beaconState: BeaconIcon.State {
        switch self {
        case .unknown: return .unknown
        case .healthy: return .healthy
        case .recovered: return .recovered
        case .down: return .down
        }
    }
    var nsColor: NSColor { BeaconIcon.color(for: beaconState) }
    var color: Color { Color(nsColor: nsColor) }
}
