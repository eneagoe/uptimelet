import Foundation

public protocol EndpointChecking: Sendable {
    func check(_ endpoint: Endpoint, timeout: TimeInterval) async -> CheckRecord
}

public struct HTTPChecker: EndpointChecking {
    private let configuration: URLSessionConfiguration
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func check(_ endpoint: Endpoint, timeout: TimeInterval) async -> CheckRecord {
        let started = Date()
        guard let url = endpoint.url else {
            return CheckRecord(endpointID: endpoint.id, address: endpoint.address, checkedAt: started,
                               isUp: false, detail: "Invalid URL")
        }
        let probe = HeaderProbe()
        let result = await probe.run(url: url, timeout: timeout, configuration: configuration)
        return CheckRecord(endpointID: endpoint.id, address: endpoint.address, checkedAt: Date(),
                           isUp: result.isUp, statusCode: result.code,
                           duration: Date().timeIntervalSince(started), detail: result.detail)
    }
}

// Stop after response headers so large pages and streaming bodies do not consume bandwidth.
// URLSession follows redirects and retains the platform's TLS certificate validation.
final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Result {
        var isUp: Bool
        var code: Int?
        var detail: String
    }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var session: URLSession?
    private var cancelled = false

    func run(url: URL, timeout: TimeInterval, configuration suppliedConfiguration: URLSessionConfiguration) async -> (isUp: Bool, code: Int?, detail: String) {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: Result(isUp: false, detail: "Cancelled"))
                    return
                }
                self.continuation = continuation
                let configuration = suppliedConfiguration.copy() as! URLSessionConfiguration
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                request.httpMethod = "GET"
                request.setValue("Uptimelet/1.0", forHTTPHeaderField: "User-Agent")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.dataTask(with: request)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(Result(isUp: false, detail: "Cancelled"), cancel: true)
        }
        return (result.isUp, result.code, result.detail)
    }

    private func finish(_ result: Result, cancel: Bool = false) {
        lock.lock()
        if cancel { cancelled = true }
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation?.resume(returning: result)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(Result(isUp: false, detail: "Non-HTTP response"))
            return
        }
        let code = response.statusCode
        let result = Result(isUp: (200..<400).contains(code), code: code,
                            detail: "HTTP \(code) · \(HTTPURLResponse.localizedString(forStatusCode: code))")
        // Resume before cancellation's completion callback can report a cancellation error.
        finish(result)
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(Result(isUp: false, detail: error?.localizedDescription ?? "No HTTP response"))
    }
}
