import XCTest
@testable import UptimeCore

final class ConfigurationTransferTests: XCTestCase {
    private let endpoint = Endpoint(name: "API", address: "https://example.com/health?probe=1",
                                    settings: MonitorSettings(pollingMinutes: 2.5, lookbackMinutes: 90, timeoutSeconds: 7))

    func testExportRoundTripPreservesAllURLConfigurationAndOmitsLogs() throws {
        let paused = Endpoint(name: "Paused café", address: "http://localhost:8080", enabled: false)
        let data = try ConfigurationTransfer.export([endpoint, paused])
        XCTAssertEqual(try ConfigurationTransfer.decode(data), [endpoint, paused])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["format", "version", "endpoints"])
        XCTAssertEqual(json["format"] as? String, "uptimelet-urls")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil(json["records"])
    }

    func testEmptyExportIsValidAndEmptyImportKeepsExistingURLs() throws {
        let imported = try ConfigurationTransfer.decode(ConfigurationTransfer.export([]))
        let result = try ConfigurationTransfer.merge(imported, into: [endpoint])
        XCTAssertEqual(result.endpoints, [endpoint])
        XCTAssertEqual(result.count, 0)
    }

    func testImportAddsURLsWithoutRemovingExistingOnesAndIsIdempotent() throws {
        let other = Endpoint(address: "https://example.org")
        let result = try ConfigurationTransfer.merge([endpoint], into: [other])
        XCTAssertEqual(result.endpoints, [other, endpoint])
        XCTAssertEqual(result.added, 1)
        let repeated = try ConfigurationTransfer.merge([endpoint], into: result.endpoints)
        XCTAssertEqual(repeated.endpoints, result.endpoints)
        XCTAssertEqual(repeated.added, 0)
        XCTAssertEqual(repeated.unchanged, 1)
    }

    func testMatchingURLUpdatesSettingsButKeepsLocalIdentityAndPosition() throws {
        let existing = Endpoint(name: "Old name", address: endpoint.address)
        let other = Endpoint(address: "https://example.org")
        var imported = endpoint
        imported.enabled = false
        let result = try ConfigurationTransfer.merge([imported], into: [other, existing])
        XCTAssertEqual(result.endpoints[0], other)
        XCTAssertEqual(result.endpoints[1].id, existing.id)
        XCTAssertEqual(result.endpoints[1].settings, endpoint.settings)
        XCTAssertEqual(result.endpoints[1].name, endpoint.name)
        XCTAssertFalse(result.endpoints[1].enabled)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 0)
    }

    func testSameIdentityWithAnotherAddressCannotOverwriteUnrelatedURL() throws {
        var collision = endpoint
        collision.address = "https://other.example.com"
        let result = try ConfigurationTransfer.merge([collision], into: [endpoint])
        XCTAssertEqual(result.endpoints[0], endpoint)
        XCTAssertEqual(result.endpoints[1].address, collision.address)
        XCTAssertNotEqual(result.endpoints[1].id, endpoint.id)
        XCTAssertEqual(result.added, 1)
        let repeated = try ConfigurationTransfer.merge([collision], into: result.endpoints)
        XCTAssertEqual(repeated.endpoints, result.endpoints)
        XCTAssertEqual(repeated.unchanged, 1)
    }

    func testIntentionallyRepeatedURLsRoundTripWithoutGrowingOnReimport() throws {
        var other = Endpoint(name: "Same site, slower", address: endpoint.address)
        other.settings.pollingMinutes = 60
        let exported = try ConfigurationTransfer.export([endpoint, other])
        let firstImport = try ConfigurationTransfer.merge(ConfigurationTransfer.decode(exported), into: [])
        XCTAssertEqual(firstImport.endpoints, [endpoint, other])
        let secondImport = try ConfigurationTransfer.merge(ConfigurationTransfer.decode(exported), into: firstImport.endpoints)
        XCTAssertEqual(secondImport.endpoints, firstImport.endpoints)
        XCTAssertEqual(secondImport.unchanged, 2)
    }

    func testWhitespaceIsNormalizedBeforeMatching() throws {
        var imported = endpoint
        imported.address = " \(endpoint.address) \n"
        imported.name = " API \n"
        let result = try ConfigurationTransfer.merge([imported], into: [endpoint])
        XCTAssertEqual(result.endpoints, [endpoint])
        XCTAssertEqual(result.unchanged, 1)
    }

    func testInvalidForeignAndFutureFilesAreRejected() throws {
        for data in [Data("not JSON".utf8), Data("[]".utf8), Data("{}".utf8),
                     Data(#"{"format":"other-app","version":1,"endpoints":[]}"#.utf8)] {
            XCTAssertThrowsError(try ConfigurationTransfer.decode(data))
        }
        let future = Data(#"{"format":"uptimelet-urls","version":2,"new-schema":true}"#.utf8)
        XCTAssertThrowsError(try ConfigurationTransfer.decode(future)) { error in
            guard case ConfigurationTransferError.unsupportedVersion(2) = error else {
                return XCTFail("Expected a version error, got \(error)")
            }
        }
    }

    func testMalformedEntryCannotPartiallyImportValidEntries() throws {
        var json = try JSONSerialization.jsonObject(with: ConfigurationTransfer.export([endpoint])) as! [String: Any]
        let valid = (json["endpoints"] as! [[String: Any]])[0]
        var bad = valid
        bad["id"] = UUID().uuidString
        bad["address"] = "ftp://example.com"
        json["endpoints"] = [valid, bad]
        XCTAssertThrowsError(try ConfigurationTransfer.decode(JSONSerialization.data(withJSONObject: json)))
        bad["address"] = "https://example.org"
        bad["settings"] = ["pollingMinutes": 0, "lookbackMinutes": 60, "timeoutSeconds": 20]
        json["endpoints"] = [bad]
        XCTAssertThrowsError(try ConfigurationTransfer.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try ConfigurationTransfer.merge([endpoint, endpoint], into: []))
    }
}
