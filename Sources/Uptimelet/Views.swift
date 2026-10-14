import SwiftUI
#if canImport(UptimeCore)
import UptimeCore
#endif

struct BeaconMark: View {
    let state: BeaconIcon.State
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: BeaconIcon.image(for: state, size: size, dark: colorScheme == .dark))
            .resizable().frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    let showSettings: () -> Void
    let showHistory: () -> Void
    let editEndpoint: (Endpoint) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BeaconMark(state: .healthy)
                Text("Uptimelet").font(.headline)
                Spacer()
                if monitor.isChecking { ProgressView().controlSize(.small) }
            }.padding()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    BeaconMark(state: monitor.overallStatus.beaconState)
                    Text(monitor.overallStatus.title).font(.title3.bold())
                }
                Text(summary).font(.caption).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 14)
            Divider()
            if monitor.state.endpoints.isEmpty {
                VStack(spacing: 12) {
                    BeaconMark(state: .unknown, size: 52)
                    Text("Keep an eye on your URLs").font(.headline)
                    Text("Add a website or health endpoint to get started.")
                        .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Add URLs…", action: showSettings).buttonStyle(.borderedProminent)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.state.endpoints) { endpoint in
                            Button { editEndpoint(endpoint) } label: {
                                EndpointRow(endpoint: endpoint, record: monitor.state.latest(for: endpoint),
                                            status: monitor.state.status(for: endpoint, at: monitor.now),
                                            isChecking: monitor.checkingEndpointIDs.contains(endpoint.id))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Edit this URL and check its status")
                            Divider().padding(.leading, 38)
                        }
                    }.padding(.horizontal)
                }.frame(maxHeight: .infinity)
            }
            if let error = monitor.storageError {
                Text(error).font(.caption).foregroundColor(.red).padding(10)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.isChecking ? "Checking URLs…" : "Next scheduled check")
                        .font(.caption).foregroundColor(.secondary)
                    if let next = monitor.nextCheck {
                        Text(next, style: .time).font(.caption.monospacedDigit())
                    } else if !monitor.isChecking {
                        Text("No active URLs").font(.caption)
                    }
                }
                Spacer()
                Button("Check now") { monitor.checkNow() }
                    .disabled(monitor.state.activeEndpoints.isEmpty || monitor.state.activeEndpoints.allSatisfy {
                        monitor.checkingEndpointIDs.contains($0.id)
                    })
            }.padding(.horizontal).padding(.vertical, 10)
            HStack {
                Button(action: showSettings) { Label("Settings", systemImage: "gearshape") }
                Button(action: showHistory) { Label("History", systemImage: "clock") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.buttonStyle(.borderless).padding(.horizontal).padding(.bottom, 12)
        }.frame(width: 390, height: 480)
    }

    private var summary: String {
        switch monitor.overallStatus {
        case .healthy: return "No failures within any URL’s status window."
        case .recovered: return "All latest checks passed; a failure is still within a URL’s status window."
        case .down: return "At least one URL failed its latest check."
        case .unknown: return "Add or enable URLs, then wait for their first check."
        }
    }
}

private struct EndpointRow: View {
    let endpoint: Endpoint
    let record: CheckRecord?
    let status: OverallStatus
    let isChecking: Bool

    private var color: Color {
        endpoint.enabled ? status.color : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BeaconMark(state: endpoint.enabled ? status.beaconState : .paused).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(endpoint.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    if isChecking { ProgressView().controlSize(.small) }
                    Text(!endpoint.enabled ? "Paused" : statusText)
                        .font(.caption.weight(.medium)).foregroundColor(color)
                }
                if !endpoint.name.isEmpty {
                    Text(endpoint.address).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Text("Every \(formatMinutes(endpoint.settings.pollingMinutes)) · Window \(formatMinutes(endpoint.settings.lookbackMinutes))")
                    .font(.caption2).foregroundColor(.secondary)
                if let record {
                    Text(record.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(record.checkedAt, style: .relative)
                        Text("ago · \(Int(record.duration * 1000)) ms")
                    }.font(.caption2).foregroundColor(.secondary)
                }
            }
        }.padding(.vertical, 12)
    }

    private var statusText: String {
        switch status {
        case .unknown: return "Pending"
        case .healthy: return "Up"
        case .recovered: return "Recovered"
        case .down: return "Down"
        }
    }

}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    let close: () -> Void
    let editEndpoint: (Endpoint) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monitored URLs").font(.title2.bold())
                    Text("Select a URL to edit its settings or check its status.")
                        .font(.callout).foregroundColor(.secondary)
                }
                Spacer()
                Button { editEndpoint(Endpoint()) } label: { Label("Add URL", systemImage: "plus") }
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(monitor.state.endpoints) { endpoint in
                        HStack(spacing: 12) {
                            Button { editEndpoint(endpoint) } label: {
                                EndpointRow(endpoint: endpoint, record: monitor.state.latest(for: endpoint),
                                            status: monitor.state.status(for: endpoint, at: monitor.now),
                                            isChecking: monitor.checkingEndpointIDs.contains(endpoint.id))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).frame(maxWidth: .infinity)
                            Button {
                                do { try monitor.removeEndpoint(endpoint.id) }
                                catch { self.error = error.localizedDescription }
                            } label: { Image(systemName: "trash") }
                            .help("Remove URL").accessibilityLabel("Remove \(endpoint.displayName)")
                        }.padding(.horizontal, 12).background(Color.primary.opacity(0.04)).cornerRadius(8)
                    }
                    if monitor.state.endpoints.isEmpty {
                        Text("No URLs yet. Add a URL to begin monitoring.")
                            .foregroundColor(.secondary).padding(30)
                    }
                }
            }
            Text("Each URL has its own polling interval, status window, and timeout. History is kept locally for 7 days.")
                .font(.caption).foregroundColor(.secondary)
            if let error { Text(error).font(.callout).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 620, minHeight: 530)
    }
}

// String bindings preserve incomplete input until Save or Check status validates it.
struct EndpointDraft {
    let id: UUID
    var name: String
    var address: String
    var enabled: Bool
    var pollingMinutes: String
    var lookbackMinutes: String
    var timeoutSeconds: String

    init(_ endpoint: Endpoint) {
        id = endpoint.id
        name = endpoint.name
        address = endpoint.address
        enabled = endpoint.enabled
        let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0...2))
        pollingMinutes = endpoint.settings.pollingMinutes.formatted(format)
        lookbackMinutes = endpoint.settings.lookbackMinutes.formatted(format)
        timeoutSeconds = endpoint.settings.timeoutSeconds.formatted(format)
    }

    func validatedEndpoint() throws -> Endpoint {
        guard let polling = parseNumber(pollingMinutes),
              let lookback = parseNumber(lookbackMinutes),
              let timeout = parseNumber(timeoutSeconds) else { throw ValidationError.invalidSettings }
        let settings = MonitorSettings(pollingMinutes: polling, lookbackMinutes: lookback, timeoutSeconds: timeout)
        let endpoint = Endpoint(id: id, name: name, address: address, enabled: enabled, settings: settings).normalized()
        try AppState(endpoints: [endpoint]).validate()
        return endpoint
    }

    private func parseNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
    }
}

struct EndpointEditorView: View {
    @ObservedObject var monitor: Monitor
    let close: () -> Void
    @State private var draft: EndpointDraft
    @State private var error: String?

    init(monitor: Monitor, endpoint: Endpoint, close: @escaping () -> Void) {
        self.monitor = monitor
        self.close = close
        _draft = State(initialValue: EndpointDraft(endpoint))
    }

    private var isChecking: Bool { monitor.checkingEndpointIDs.contains(draft.id) }
    private var latest: CheckRecord? {
        let endpoint = Endpoint(id: draft.id, address: draft.address).normalized()
        return monitor.state.latest(for: endpoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("URL settings").font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Name (optional)").font(.callout.weight(.medium))
                TextField("Website or service name", text: $draft.name)
                Text("URL").font(.callout.weight(.medium)).padding(.top, 6)
                TextField("https://example.com/health", text: $draft.address)
            }.textFieldStyle(.roundedBorder)
            Toggle("Poll this URL automatically", isOn: $draft.enabled)
            HStack(alignment: .top, spacing: 20) {
                numericField("Check every", value: $draft.pollingMinutes, unit: "minutes")
                numericField("Status window", value: $draft.lookbackMinutes, unit: "minutes")
                numericField("Timeout", value: $draft.timeoutSeconds, unit: "seconds")
            }
            Text("Yellow means this URL recovered from a failure within its status window. A failed latest check stays red.")
                .font(.caption).foregroundColor(.secondary)
            Divider()
            HStack {
                Text("Latest check").font(.headline)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                Button("Check status") { save(check: true, closeAfter: false) }
                    .disabled(isChecking)
            }
            if let latest {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        BeaconMark(state: latest.isUp ? .healthy : .down)
                        Text(latest.isUp ? "Up" : "Down")
                            .foregroundColor(latest.isUp ? OverallStatus.healthy.color : OverallStatus.down.color)
                    }.font(.callout.weight(.semibold))
                    Text(latest.detail).font(.callout).textSelection(.enabled)
                    Text(latest.checkedAt, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption).foregroundColor(.secondary)
                    Text("Response time: \(Int(latest.duration * 1000)) ms").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text(isChecking ? "Checking this URL…" : "This URL has not been checked yet.")
                    .font(.callout).foregroundColor(.secondary)
            }
            if draft.enabled, let next = monitor.nextChecks[draft.id] {
                HStack(spacing: 4) {
                    Text("Next scheduled check:")
                    Text(next, style: .time)
                }.font(.caption).foregroundColor(.secondary)
            }
            Text("Check status saves your edits and checks only this URL. Paused URLs can still be checked manually.")
                .font(.caption).foregroundColor(.secondary)
            if let error { Text(error).font(.callout).foregroundColor(.red) }
            if let storageError = monitor.storageError {
                Text(storageError).font(.caption).foregroundColor(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") { save(check: false, closeAfter: true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(minWidth: 500, minHeight: 570)
    }

    private func numericField(_ title: String, value: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 4) {
                TextField(title, text: value).textFieldStyle(.roundedBorder).frame(width: 65)
                Text(unit).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func save(check: Bool, closeAfter: Bool) {
        do {
            let endpoint = try draft.validatedEndpoint()
            try monitor.saveEndpoint(endpoint)
            if check || (endpoint.enabled && monitor.state.latest(for: endpoint) == nil) {
                monitor.checkNow(endpointID: endpoint.id)
            }
            error = nil
            if closeAfter { close() }
        } catch { self.error = error.localizedDescription }
    }
}

struct HistoryView: View {
    @ObservedObject var monitor: Monitor
    @State private var endpointID: UUID?
    @State private var failuresOnly = false
    @State private var displayLimit = 200

    private var filteredRecords: [CheckRecord] {
        monitor.state.records.filter {
            (endpointID == nil || $0.endpointID == endpointID) && (!failuresOnly || !$0.isUp)
        }.sorted { $0.checkedAt > $1.checkedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check history").font(.title2.bold())
                    Text("Last 7 days · \(filteredRecords.count) checks").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Picker("URL", selection: $endpointID) {
                    Text("All URLs").tag(Optional<UUID>.none)
                    ForEach(monitor.state.endpoints) { endpoint in
                        Text(endpoint.displayName).tag(Optional(endpoint.id))
                    }
                }.frame(maxWidth: 250)
                Toggle("Failures only", isOn: $failuresOnly)
            }
            Divider()
            if filteredRecords.isEmpty {
                Text("No checks to show.").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(filteredRecords.prefix(displayLimit))) { record in
                        HStack(alignment: .top, spacing: 12) {
                            BeaconMark(state: record.isUp ? .healthy : .down)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.address).font(.callout.weight(.medium)).textSelection(.enabled)
                                Text(record.detail).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(record.checkedAt, format: .dateTime.month().day().hour().minute().second())
                                Text("\(Int(record.duration * 1000)) ms")
                            }.font(.caption).foregroundColor(.secondary)
                        }.padding(.vertical, 6)
                    }
                    if filteredRecords.count > displayLimit {
                        Button("Show 200 more checks") { displayLimit += 200 }
                    }
                }.listStyle(.inset)
            }
        }.padding(24).frame(minWidth: 730, minHeight: 500)
        .onChange(of: endpointID) { _ in displayLimit = 200 }
        .onChange(of: failuresOnly) { _ in displayLimit = 200 }
    }
}

private func formatMinutes(_ minutes: Double) -> String {
    if minutes.truncatingRemainder(dividingBy: 60) == 0 {
        let hours = Int(minutes / 60)
        return "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
    return "\(minutes.formatted()) minutes"
}
