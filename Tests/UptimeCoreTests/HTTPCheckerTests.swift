import XCTest
@testable import UptimeCore

final class HTTPCheckerTests: XCTestCase {
    private func checker() -> HTTPChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HTTPChecker(configuration: configuration)
    }

    func testHTTPStatusClassification() async {
        for code in [200, 204, 301, 399, 400, 401, 404, 500, 503] {
            let endpoint = Endpoint(address: "https://status.test/\(code)")
            let record = await checker().check(endpoint, timeout: 2)
            XCTAssertEqual(record.isUp, (200..<400).contains(code))
            XCTAssertEqual(record.statusCode, code, record.detail)
            XCTAssertEqual(record.endpointID, endpoint.id)
            XCTAssertEqual(record.address, endpoint.address)
            XCTAssertTrue(record.detail.contains("\(code)"))
            XCTAssertGreaterThanOrEqual(record.duration, 0)
        }
    }

    func testTransportAndTimeoutErrorsAreDown() async {
        for path in ["offline", "timeout", "tls"] {
            let record = await checker().check(Endpoint(address: "https://status.test/\(path)"), timeout: 2)
            XCTAssertFalse(record.isUp)
            XCTAssertNil(record.statusCode)
            XCTAssertFalse(record.detail.isEmpty)
        }
    }

    func testHeaderCallbackFinishesWithoutBodyAndIgnoresLaterCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let probe = HeaderProbe()
        let url = URL(string: "https://status.test/hang")!
        let running = Task { await probe.run(url: url, timeout: 2, configuration: configuration) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        var disposition: URLSession.ResponseDisposition?
        probe.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
        probe.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        let result = await running.value
        XCTAssertEqual(disposition, .cancel)
        XCTAssertTrue(result.isUp)
        XCTAssertEqual(result.code, 200)
    }

    func testInvalidURLIsDownWithoutNetworkRequest() async {
        let record = await checker().check(Endpoint(address: "not a URL"), timeout: 2)
        XCTAssertFalse(record.isUp)
        XCTAssertEqual(record.detail, "Invalid URL")
    }

    func testCancellationBeforeRequestFinishes() async throws {
        let checker = checker()
        let task = Task { await checker.check(Endpoint(address: "https://status.test/hang"), timeout: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let record = await task.value
        XCTAssertFalse(record.isUp)
        XCTAssertEqual(record.detail, "Cancelled")
    }

    func testCancellationBeforeRequestStarts() async {
        let checker = checker()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await checker.check(Endpoint(address: "https://status.test/hang"), timeout: 2)
        }
        let record = await task.value
        XCTAssertFalse(record.isUp)
        XCTAssertEqual(record.detail, "Cancelled")
    }
}

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "hang" { return }
        let errors: [String: URLError.Code] = ["offline": .cannotConnectToHost, "timeout": .timedOut, "tls": .serverCertificateUntrusted]
        if let error = errors[path] {
            client?.urlProtocol(self, didFailWithError: URLError(error))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: Int(path)!, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Foundation's custom URLProtocol bridge buffers callbacks until
            // completion. The header-only path is tested directly above.
            client?.urlProtocol(self, didLoad: Data([0]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
