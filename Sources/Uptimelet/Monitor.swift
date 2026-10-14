import AppKit
import Combine
#if canImport(UptimeCore)
import UptimeCore
#endif

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var state = AppState()
    @Published private(set) var checkingEndpointIDs = Set<UUID>()
    @Published private(set) var now = Date()
    @Published private(set) var nextChecks: [UUID: Date] = [:]
    @Published private(set) var storageError: String?

    private let store: StateStore
    private let checker: any EndpointChecking
    private var timer: Timer?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTokens: [UUID: UUID] = [:]
    private var pending: [Endpoint] = []
    private var canSave = true
    private var wakeObserver: NSObjectProtocol?

    var overallStatus: OverallStatus { state.overallStatus(at: now) }
    var isChecking: Bool { !checkingEndpointIDs.isEmpty }
    var nextCheck: Date? { nextChecks.values.min() }

    init(store: StateStore = .applicationStore, checker: any EndpointChecking = HTTPChecker()) {
        self.store = store
        self.checker = checker
        do {
            state = try store.load()
        } catch {
            canSave = false
            storageError = "Could not load saved data: \(error.localizedDescription) The original file is preserved; changes will not be saved."
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
                self?.checkNow()
            }
        }
        // Persist migrated endpoint settings even when all URLs are paused.
        persist()
        checkNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        activeTokens.removeAll()
        pending.removeAll()
        for task in runningTasks.values { task.cancel() }
        checkingEndpointIDs.removeAll()
        nextChecks.removeAll()
        persist()
    }

    func update(endpoints: [Endpoint]) throws {
        var updated = state
        updated.endpoints = endpoints.map { $0.normalized() }
        try updated.validate()
        apply(updated)
        persist()
    }

    private func apply(_ updated: AppState) {
        let previous = Dictionary(uniqueKeysWithValues: state.endpoints.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: updated.endpoints.map { ($0.id, $0) })
        for endpoint in state.endpoints where current[endpoint.id] != endpoint {
            cancel(endpoint.id)
        }
        state = updated
        now = Date()
        for endpoint in state.endpoints where previous[endpoint.id] != endpoint {
            if endpoint.enabled {
                let last = state.latest(for: endpoint)?.checkedAt ?? now.addingTimeInterval(-endpoint.settings.pollingMinutes * 60)
                nextChecks[endpoint.id] = last.addingTimeInterval(endpoint.settings.pollingMinutes * 60)
            }
        }
        drainQueue()
    }

    func exportConfiguration() throws -> Data {
        try ConfigurationTransfer.export(state.endpoints)
    }

    @discardableResult
    func importConfiguration(_ data: Data) throws -> ConfigurationImport {
        let imported = try ConfigurationTransfer.decode(data)
        let result = try ConfigurationTransfer.merge(imported, into: state.endpoints)
        guard canSave else { throw ConfigurationTransferError.storageUnavailable }
        var updated = state
        updated.endpoints = result.endpoints
        let previous = Dictionary(uniqueKeysWithValues: state.endpoints.map { ($0.id, $0) })
        // Save first: malformed files or failed writes cannot partially change live settings.
        try store.save(updated)
        apply(updated)
        storageError = nil
        for endpoint in state.activeEndpoints where previous[endpoint.id] != endpoint {
            checkNow(endpointID: endpoint.id)
        }
        return result
    }

    func saveEndpoint(_ endpoint: Endpoint) throws {
        var endpoints = state.endpoints
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint }
        else { endpoints.append(endpoint) }
        try update(endpoints: endpoints)
    }

    func removeEndpoint(_ id: UUID) throws {
        try update(endpoints: state.endpoints.filter { $0.id != id })
    }

    // A clock input lets tests verify independent due times without waiting minutes.
    func tick(at date: Date = Date()) {
        now = date
        if state.prune(at: now) { persist() }
        let due = state.activeEndpoints.filter { endpoint in
            guard let next = nextChecks[endpoint.id] else { return false }
            return next <= now
        }
        for endpoint in due { enqueue(endpoint) }
        drainQueue()
    }

    func checkNow() {
        for endpoint in state.activeEndpoints { enqueue(endpoint) }
        drainQueue()
    }

    func checkNow(endpointID: UUID) {
        guard let endpoint = state.endpoints.first(where: { $0.id == endpointID }) else { return }
        // A paused URL can be checked explicitly without enabling automatic polling.
        enqueue(endpoint)
        drainQueue()
    }

    private func enqueue(_ endpoint: Endpoint) {
        guard !checkingEndpointIDs.contains(endpoint.id) else { return }
        checkingEndpointIDs.insert(endpoint.id)
        nextChecks.removeValue(forKey: endpoint.id)
        pending.append(endpoint)
    }

    private func cancel(_ id: UUID) {
        if let token = activeTokens.removeValue(forKey: id) { runningTasks[token]?.cancel() }
        pending.removeAll { $0.id == id }
        checkingEndpointIDs.remove(id)
        nextChecks.removeValue(forKey: id)
        // Cancelled tasks hold their concurrency slot until they actually finish.
    }

    private func drainQueue() {
        while runningTasks.count < 6, !pending.isEmpty {
            let endpoint = pending.removeFirst()
            let token = UUID()
            activeTokens[endpoint.id] = token
            let checker = self.checker
            runningTasks[token] = Task { [weak self] in
                let record = await checker.check(endpoint, timeout: endpoint.settings.timeoutSeconds)
                guard let self else { return }
                self.runningTasks.removeValue(forKey: token)
                if self.activeTokens[endpoint.id] == token {
                    self.activeTokens.removeValue(forKey: endpoint.id)
                    self.checkingEndpointIDs.remove(endpoint.id)
                    self.now = Date()
                    self.state.records.append(record)
                    self.state.prune(at: self.now)
                    if endpoint.enabled {
                        self.nextChecks[endpoint.id] = self.now.addingTimeInterval(endpoint.settings.pollingMinutes * 60)
                    }
                    self.persist()
                }
                self.drainQueue()
            }
        }
    }

    private func persist() {
        guard canSave else { return }
        do {
            try store.save(state)
            storageError = nil
        } catch {
            storageError = "Could not save settings and history: \(error.localizedDescription)"
        }
    }
}
