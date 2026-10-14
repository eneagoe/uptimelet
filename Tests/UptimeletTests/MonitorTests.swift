import XCTest
import UptimeCore
@testable import Uptimelet

final class MonitorTests: XCTestCase {
    private func temporaryStore() -> StateStore {
        StateStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Polling did not settle within 2 seconds")
    }

    @MainActor
    func testNoActiveURLsDoNotScheduleChecks() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        monitor.checkNow()
        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.nextCheck)
    }

    @MainActor
    func testRoundIsBoundedDoesNotOverlapAndPersistsEveryResult() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = RecordingChecker()
        let monitor = Monitor(store: store, checker: checker)
        let endpoints = (1...14).map { Endpoint(address: "https://example.com/\($0)") }
        try monitor.update(endpoints: endpoints)
        monitor.checkNow()
        XCTAssertTrue(monitor.isChecking)
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let stats = await checker.statistics()
        XCTAssertEqual(stats.count, 14)
        XCTAssertLessThanOrEqual(stats.maximum, 6)
        XCTAssertEqual(monitor.state.records.count, 14)
        XCTAssertEqual(monitor.overallStatus, .healthy)
        XCTAssertEqual(monitor.nextCheck!.timeIntervalSince(monitor.now), 600, accuracy: 0.2)
        XCTAssertEqual(try store.load().records.count, 14)
    }

    @MainActor
    func testConfigurationChangeDiscardsStaleInFlightResults() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = RecordingChecker(delay: 200_000_000)
        let monitor = Monitor(store: store, checker: checker)
        let original = Endpoint(address: "https://example.com/old")
        try monitor.update(endpoints: [original])
        monitor.checkNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        var edited = original
        edited.address = "https://example.com/new"
        edited.settings.pollingMinutes = 2
        try monitor.saveEndpoint(edited)
        monitor.checkNow(endpointID: edited.id)
        try await waitUntil { !monitor.isChecking }
        XCTAssertEqual(monitor.state.records.map(\.address), [edited.address])
        XCTAssertEqual(monitor.nextCheck!.timeIntervalSince(monitor.now), 120, accuracy: 0.1)
    }

    @MainActor
    func testPausingAllURLsCancelsRoundAndClearsSchedule() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker(delay: 200_000_000))
        var endpoint = Endpoint(address: "https://example.com")
        try monitor.update(endpoints: [endpoint])
        monitor.checkNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        endpoint.enabled = false
        try monitor.update(endpoints: [endpoint])
        monitor.checkNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.nextCheck)
        XCTAssertTrue(monitor.state.records.isEmpty)
        XCTAssertEqual(monitor.overallStatus, .unknown)
    }

    @MainActor
    func testRemovingURLPreservesItsLog() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        try monitor.update(endpoints: [Endpoint(address: "https://example.com")])
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        try monitor.update(endpoints: [])
        XCTAssertEqual(monitor.state.records.count, 1)
        XCTAssertEqual(monitor.overallStatus, .unknown)
        XCTAssertEqual(try store.load().records.count, 1)
    }

    @MainActor
    func testInvalidSettingsDoNotCancelOrOverwriteCurrentConfiguration() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        let invalid = Endpoint(address: "https://example.com", settings: MonitorSettings(pollingMinutes: 0))
        XCTAssertThrowsError(try monitor.saveEndpoint(invalid))
        XCTAssertTrue(monitor.state.endpoints.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @MainActor
    func testOnlyDueURLIsPolledAtItsOwnInterval() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = RecordingChecker()
        let monitor = Monitor(store: store, checker: checker)
        let fast = Endpoint(address: "https://example.com/fast", settings: MonitorSettings(pollingMinutes: 1))
        let slow = Endpoint(address: "https://example.com/slow", settings: MonitorSettings(pollingMinutes: 10))
        try monitor.update(endpoints: [fast, slow])
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let schedules = monitor.nextChecks
        XCTAssertEqual(schedules[slow.id]!.timeIntervalSince(schedules[fast.id]!), 540, accuracy: 0.2)
        monitor.tick(at: schedules[fast.id]!.addingTimeInterval(0.1))
        try await waitUntil { !monitor.isChecking }
        XCTAssertEqual(monitor.state.records.filter { $0.endpointID == fast.id }.count, 2)
        XCTAssertEqual(monitor.state.records.filter { $0.endpointID == slow.id }.count, 1)
        XCTAssertEqual(monitor.nextChecks[slow.id], schedules[slow.id])
    }

    @MainActor
    func testSingleURLCheckLeavesOtherURLsAndSchedulesAlone() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = RecordingChecker()
        let monitor = Monitor(store: store, checker: checker)
        let first = Endpoint(address: "https://example.com/one")
        let second = Endpoint(address: "https://example.com/two")
        try monitor.update(endpoints: [first, second])
        let otherSchedule = monitor.nextChecks[second.id]
        monitor.checkNow(endpointID: first.id)
        monitor.checkNow(endpointID: first.id)
        try await waitUntil { !monitor.isChecking }
        XCTAssertEqual(monitor.state.records.map(\.endpointID), [first.id])
        XCTAssertEqual(monitor.nextChecks[second.id], otherSchedule)
        let stats = await checker.statistics()
        XCTAssertEqual(stats.count, 1)
    }

    @MainActor
    func testCheckingOneURLWhileAnotherRunsDoesNotCancelEither() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker(delay: 100_000_000))
        let first = Endpoint(address: "https://example.com/one")
        let second = Endpoint(address: "https://example.com/two")
        try monitor.update(endpoints: [first, second])
        monitor.checkNow(endpointID: first.id)
        monitor.checkNow(endpointID: second.id)
        XCTAssertEqual(monitor.checkingEndpointIDs, Set([first.id, second.id]))
        try await waitUntil { !monitor.isChecking }
        XCTAssertEqual(Set(monitor.state.records.map(\.endpointID)), Set([first.id, second.id]))
    }

    @MainActor
    func testEditingOneURLKeepsOtherURLScheduleAndLogs() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        var first = Endpoint(address: "https://example.com/one")
        let second = Endpoint(address: "https://example.com/two")
        try monitor.update(endpoints: [first, second])
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let otherSchedule = monitor.nextChecks[second.id]
        first.settings.pollingMinutes = 2
        first.settings.lookbackMinutes = 15
        try monitor.saveEndpoint(first)
        monitor.checkNow(endpointID: first.id)
        try await waitUntil { !monitor.isChecking }
        XCTAssertEqual(monitor.nextChecks[second.id], otherSchedule)
        XCTAssertEqual(monitor.state.records.filter { $0.endpointID == second.id }.count, 1)
        XCTAssertEqual(monitor.state.endpoints.first(where: { $0.id == second.id }), second)
        XCTAssertEqual(monitor.nextChecks[first.id]!.timeIntervalSince(monitor.now), 120, accuracy: 0.1)
    }

    @MainActor
    func testEachURLUsesItsOwnTimeoutAndPausedURLCanBeCheckedManually() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = RecordingChecker()
        let monitor = Monitor(store: store, checker: checker)
        let paused = Endpoint(address: "https://example.com/paused", enabled: false, settings: MonitorSettings(timeoutSeconds: 3))
        let active = Endpoint(address: "https://example.com/active", settings: MonitorSettings(timeoutSeconds: 11))
        try monitor.update(endpoints: [paused, active])
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        XCTAssertNil(monitor.state.latest(for: paused))
        monitor.checkNow(endpointID: paused.id)
        try await waitUntil { !monitor.isChecking }
        XCTAssertTrue(monitor.state.latest(for: paused)!.isUp)
        XCTAssertFalse(monitor.state.endpoints.first(where: { $0.id == paused.id })!.enabled)
        XCTAssertNil(monitor.nextChecks[paused.id])
        let timeouts = await checker.requestTimeouts()
        XCTAssertEqual(timeouts[paused.id], 3)
        XCTAssertEqual(timeouts[active.id], 11)
    }

    func testEditorDraftValidatesAndPreservesPerURLSettings() throws {
        let endpoint = Endpoint(address: "https://example.com", settings: MonitorSettings(pollingMinutes: 2, lookbackMinutes: 15, timeoutSeconds: 5))
        var draft = EndpointDraft(endpoint)
        XCTAssertEqual(try draft.validatedEndpoint(), endpoint)
        draft.name = " API "
        draft.address = " https://example.com/health "
        draft.pollingMinutes = "3"
        let edited = try draft.validatedEndpoint()
        XCTAssertEqual(edited.id, endpoint.id)
        XCTAssertEqual(edited.name, "API")
        XCTAssertEqual(edited.address, "https://example.com/health")
        XCTAssertEqual(edited.settings.pollingMinutes, 3)
        XCTAssertEqual(edited.settings.lookbackMinutes, 15)
        draft.pollingMinutes = "invalid"
        XCTAssertThrowsError(try draft.validatedEndpoint())
        draft.pollingMinutes = "0"
        XCTAssertThrowsError(try draft.validatedEndpoint())
        draft.pollingMinutes = "1"
        draft.address = "not a URL"
        XCTAssertThrowsError(try draft.validatedEndpoint())
    }

    @MainActor
    func testImportPreservesHistoryPersistsSettingsAndStartsOnlyChangedURLs() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        let original = Endpoint(name: "Local", address: "https://example.com/one")
        let untouched = Endpoint(address: "https://example.com/two")
        try monitor.update(endpoints: [original, untouched])
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let logs = monitor.state.records
        let untouchedSchedule = monitor.nextChecks[untouched.id]
        let imported = Endpoint(name: "Imported", address: original.address, settings: MonitorSettings(pollingMinutes: 3))
        let added = Endpoint(address: "https://example.com/new", enabled: false)
        let data = try ConfigurationTransfer.export([imported, added])
        let result = try monitor.importConfiguration(data)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(monitor.state.records, logs)
        XCTAssertEqual(monitor.checkingEndpointIDs, [original.id])
        XCTAssertEqual(monitor.nextChecks[untouched.id], untouchedSchedule)
        XCTAssertEqual(monitor.state.endpoints[0].id, original.id)
        XCTAssertEqual(monitor.state.endpoints[0].settings.pollingMinutes, 3)
        XCTAssertEqual(try store.load().endpoints, monitor.state.endpoints)
        try await waitUntil { !monitor.isChecking }
        let repeated = try monitor.importConfiguration(data)
        XCTAssertEqual(repeated.unchanged, 2)
        XCTAssertFalse(monitor.isChecking)
        XCTAssertEqual(monitor.state.endpoints.count, 3)
        XCTAssertEqual(monitor.state.records.filter { $0.endpointID == untouched.id }.count, 1)
        XCTAssertTrue(logs.allSatisfy { monitor.state.records.contains($0) })
    }

    @MainActor
    func testInvalidImportLeavesSettingsLogsAndScheduleUntouched() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        let endpoint = Endpoint(address: "https://example.com")
        try monitor.saveEndpoint(endpoint)
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let state = monitor.state
        let schedules = monitor.nextChecks
        let saved = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try monitor.importConfiguration(Data("not JSON".utf8)))
        XCTAssertEqual(monitor.state, state)
        XCTAssertEqual(monitor.nextChecks, schedules)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), saved)
    }

    @MainActor
    func testImportWriteFailureCannotChangeLiveConfiguration() throws {
        let store = temporaryStore()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        try Data("blocked parent directory".utf8).write(to: directory)
        let data = try ConfigurationTransfer.export([Endpoint(address: "https://example.com")])
        XCTAssertThrowsError(try monitor.importConfiguration(data))
        XCTAssertTrue(monitor.state.endpoints.isEmpty)
        XCTAssertFalse(monitor.isChecking)
        XCTAssertNil(monitor.nextCheck)
    }

    @MainActor
    func testMonitorExportContainsURLsAndNoCheckHistory() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let monitor = Monitor(store: store, checker: RecordingChecker())
        try monitor.saveEndpoint(Endpoint(address: "https://example.com"))
        monitor.checkNow()
        try await waitUntil { !monitor.isChecking }
        let exported = try monitor.exportConfiguration()
        XCTAssertEqual(try ConfigurationTransfer.decode(exported), monitor.state.endpoints)
        let json = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        XCTAssertNil(json["records"])
        XCTAssertFalse(monitor.state.records.isEmpty)
    }
}

private actor RecordingChecker: EndpointChecking {
    private let delay: UInt64
    private var count = 0
    private var active = 0
    private var maximum = 0
    private var timeouts: [UUID: TimeInterval] = [:]

    init(delay: UInt64 = 20_000_000) { self.delay = delay }

    func check(_ endpoint: Endpoint, timeout: TimeInterval) async -> CheckRecord {
        count += 1
        timeouts[endpoint.id] = timeout
        active += 1
        maximum = max(maximum, active)
        // Still return a result on cancellation to exercise stale-result guards.
        try? await Task.sleep(nanoseconds: delay)
        active -= 1
        return CheckRecord(endpointID: endpoint.id, address: endpoint.address, checkedAt: Date(),
                           isUp: true, statusCode: 200, detail: "HTTP 200")
    }

    func statistics() -> (count: Int, maximum: Int) { (count, maximum) }
    func requestTimeouts() -> [UUID: TimeInterval] { timeouts }
}
