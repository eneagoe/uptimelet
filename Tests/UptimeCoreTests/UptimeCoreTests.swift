import XCTest
@testable import UptimeCore

final class UptimeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let first = Endpoint(name: "API", address: "https://example.com/health")
    private let second = Endpoint(name: "Site", address: "http://example.org")

    private func record(_ endpoint: Endpoint, up: Bool, minutesAgo: Double = 0) -> CheckRecord {
        CheckRecord(endpointID: endpoint.id, address: endpoint.address,
                    checkedAt: now.addingTimeInterval(-minutesAgo * 60), isUp: up,
                    statusCode: up ? 200 : 503, detail: up ? "HTTP 200" : "HTTP 503")
    }

    func testDefaults() {
        let settings = MonitorSettings()
        XCTAssertEqual(settings.pollingMinutes, 10)
        XCTAssertEqual(settings.lookbackMinutes, 60)
        XCTAssertEqual(AppState.retention, 604_800)
        XCTAssertTrue(settings.isValid)
    }

    func testNoURLsAndUncheckedURLsAreUnknown() {
        XCTAssertEqual(AppState().overallStatus(at: now), .unknown)
        XCTAssertEqual(AppState(endpoints: [first]).overallStatus(at: now), .unknown)
        let state = AppState(endpoints: [first, second], records: [record(first, up: true)])
        XCTAssertEqual(state.overallStatus(at: now), .unknown)
    }

    func testAllSuccessesAreGreen() {
        let state = AppState(endpoints: [first, second], records: [record(first, up: true), record(second, up: true)])
        XCTAssertEqual(state.overallStatus(at: now), .healthy)
    }

    func testLatestFailureIsRedEvenOutsideWindow() {
        let state = AppState(endpoints: [first, second], records: [record(first, up: true), record(second, up: false, minutesAgo: 120)])
        XCTAssertEqual(state.overallStatus(at: now), .down)
    }

    func testLatestFailureWinsOverRecoveryAndUnknown() {
        let state = AppState(endpoints: [first, second], records: [record(first, up: false)])
        XCTAssertEqual(state.overallStatus(at: now), .down)
    }

    func testRecoveryIsYellowAndExpiresWithoutAnotherCheck() {
        let state = AppState(endpoints: [first], records: [record(first, up: false, minutesAgo: 30), record(first, up: true)])
        XCTAssertEqual(state.overallStatus(at: now), .recovered)
        XCTAssertEqual(state.overallStatus(at: now.addingTimeInterval(31 * 60)), .healthy)
    }

    func testWindowIsConfigurableAndIncludesBoundary() {
        let records = [record(first, up: false, minutesAgo: 60), record(first, up: true)]
        XCTAssertEqual(AppState(endpoints: [first], records: records).overallStatus(at: now), .recovered)
        var endpoint = first
        endpoint.settings.lookbackMinutes = 15
        let state = AppState(endpoints: [endpoint], records: records)
        XCTAssertEqual(state.overallStatus(at: now), .healthy)
    }

    func testDisabledAndRemovedURLsDoNotAffectStatus() {
        var paused = second
        paused.enabled = false
        let records = [record(first, up: true), record(second, up: false)]
        XCTAssertEqual(AppState(endpoints: [first, paused], records: records).overallStatus(at: now), .healthy)
        XCTAssertEqual(AppState(endpoints: [first], records: records).overallStatus(at: now), .healthy)
        XCTAssertEqual(AppState(endpoints: [paused], records: records).overallStatus(at: now), .unknown)
    }

    func testChangedURLDoesNotReuseOldResult() {
        var edited = first
        edited.address = "https://example.com/new"
        let state = AppState(endpoints: [edited], records: [record(first, up: false)])
        XCTAssertNil(state.latest(for: edited))
        XCTAssertEqual(state.overallStatus(at: now), .unknown)
    }

    func testUnsortedHistoryUsesNewestTimestamp() {
        let state = AppState(endpoints: [first], records: [record(first, up: true), record(first, up: false, minutesAgo: 120)])
        XCTAssertTrue(state.latest(for: first)!.isUp)
        XCTAssertEqual(state.overallStatus(at: now), .healthy)
    }

    func testPruneRemovesOnlyRecordsOlderThanOneWeek() {
        var state = AppState(endpoints: [first], records: [
            record(first, up: false, minutesAgo: 10081),
            record(first, up: true, minutesAgo: 10080), record(first, up: true)
        ])
        XCTAssertTrue(state.prune(at: now))
        XCTAssertEqual(state.records.count, 2)
        XCTAssertFalse(state.prune(at: now))
    }

    func testURLValidationAndNormalization() {
        for address in ["https://example.com", "http://localhost:8080/health?probe=1", "https://[::1]/health"] {
            XCTAssertNotNil(Endpoint(address: address).url, address)
        }
        for address in ["example.com", "ftp://example.com", "https://", "http:///", "https://user:secret@example.com"] {
            XCTAssertNil(Endpoint(address: address).url, address)
        }
        let normalized = Endpoint(name: " API \n", address: " https://example.com \n").normalized()
        XCTAssertEqual(normalized.name, "API")
        XCTAssertEqual(normalized.address, "https://example.com")
    }

    func testInvalidSettingsAndDuplicateIDsAreRejected() {
        for settings in [MonitorSettings(pollingMinutes: 0), MonitorSettings(pollingMinutes: .nan),
                         MonitorSettings(lookbackMinutes: 10081), MonitorSettings(timeoutSeconds: 121)] {
            var endpoint = first
            endpoint.settings = settings
            XCTAssertThrowsError(try AppState(endpoints: [endpoint]).validate())
        }
        XCTAssertThrowsError(try AppState(endpoints: [first, first]).validate())
        XCTAssertThrowsError(try AppState(endpoints: [Endpoint(address: "bad")]).validate())
    }

    func testPersistenceRoundTripAndPruningOnSaveAndLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(fileURL: directory.appendingPathComponent("nested/state.json"))
        XCTAssertEqual(try store.load(at: now), AppState())
        var endpoint = first
        endpoint.settings.pollingMinutes = 3
        let state = AppState(endpoints: [endpoint], records: [
            record(first, up: false, minutesAgo: 10081), record(first, up: true)
        ])
        try store.save(state, at: now)
        let restored = try store.load(at: now)
        XCTAssertEqual(restored.endpoints, [endpoint])
        XCTAssertEqual(restored.endpoints[0].settings.pollingMinutes, 3)
        XCTAssertEqual(restored.records, [state.records[1]])
        XCTAssertTrue(try store.load(at: now.addingTimeInterval(AppState.retention + 1)).records.isEmpty)
        let persisted = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: store.fileURL))
        XCTAssertTrue(persisted.records.isEmpty)
    }

    func testCorruptDataIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try StateStore(fileURL: file).load())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testEachURLUsesItsOwnHistoryWindow() {
        var shortWindow = first
        shortWindow.settings.lookbackMinutes = 15
        var longWindow = second
        longWindow.settings.lookbackMinutes = 120
        let state = AppState(endpoints: [shortWindow, longWindow], records: [
            record(first, up: false, minutesAgo: 30), record(first, up: true),
            record(second, up: false, minutesAgo: 90), record(second, up: true)
        ])
        XCTAssertEqual(state.status(for: shortWindow, at: now), .healthy)
        XCTAssertEqual(state.status(for: longWindow, at: now), .recovered)
        XCTAssertEqual(state.overallStatus(at: now), .recovered)
        XCTAssertEqual(state.overallStatus(at: now.addingTimeInterval(31 * 60)), .healthy)
    }

    func testLegacyGlobalSettingsMigrateToEachURLAndKeepLogs() throws {
        let state = AppState(endpoints: [first, second], records: [record(first, up: true)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var endpoints = json["endpoints"] as! [[String: Any]]
        for index in endpoints.indices { endpoints[index].removeValue(forKey: "settings") }
        json["endpoints"] = endpoints
        json["settings"] = ["pollingMinutes": 7.5, "lookbackMinutes": 90, "timeoutSeconds": 12]
        let migrated = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        try migrated.validate()
        XCTAssertEqual(migrated.endpoints.map(\.settings), Array(repeating: MonitorSettings(pollingMinutes: 7.5, lookbackMinutes: 90, timeoutSeconds: 12), count: 2))
        XCTAssertEqual(migrated.records, state.records)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
        XCTAssertNil(encoded["settings"])
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(migrated)), migrated)
    }

    func testLegacyMigrationPreservesExplicitEndpointSettings() throws {
        let endpoint = Endpoint(address: "https://example.com", settings: MonitorSettings(pollingMinutes: 2, lookbackMinutes: 15))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState(endpoints: [endpoint]))) as! [String: Any]
        json["settings"] = ["pollingMinutes": 30, "lookbackMinutes": 180, "timeoutSeconds": 20]
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.endpoints, [endpoint])
    }

    func testLegacyEndpointWithoutGlobalSettingsUsesDefaults() throws {
        let state = AppState(endpoints: [first])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var endpoints = json["endpoints"] as! [[String: Any]]
        endpoints[0].removeValue(forKey: "settings")
        json["endpoints"] = endpoints
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.endpoints[0].settings, MonitorSettings())
    }

    func testBrandRenameMigratesDataWithoutModifyingOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyFile = directory.appendingPathComponent("StatusCheck/state.json")
        let newFile = directory.appendingPathComponent("Uptimelet/state.json")
        let state = AppState(endpoints: [first], records: [record(first, up: true)])
        try StateStore(fileURL: legacyFile).save(state, at: now)
        let original = try Data(contentsOf: legacyFile)
        let renamed = StateStore(fileURL: newFile, legacyFileURL: legacyFile)
        XCTAssertEqual(try renamed.load(at: now), state)
        XCTAssertEqual(try Data(contentsOf: legacyFile), original)
        XCTAssertEqual(try StateStore(fileURL: newFile).load(at: now), state)
        var updated = state
        updated.endpoints[0].settings.pollingMinutes = 2
        try renamed.save(updated, at: now)
        XCTAssertEqual(try renamed.load(at: now), updated)
    }

    func testBrandMigrationPreservesCorruptLegacyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("old.json")
        let newFile = directory.appendingPathComponent("new.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: legacy)
        XCTAssertThrowsError(try StateStore(fileURL: newFile, legacyFileURL: legacy).load(at: now))
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
    }
}
