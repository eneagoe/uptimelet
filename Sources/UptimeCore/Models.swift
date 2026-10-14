import Foundation

public struct Endpoint: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var enabled: Bool
    public var settings: MonitorSettings

    public init(id: UUID = UUID(), name: String = "", address: String = "", enabled: Bool = true,
                settings: MonitorSettings = MonitorSettings()) {
        self.id = id
        self.name = name
        self.address = address
        self.enabled = enabled
        self.settings = settings
    }

    fileprivate enum CodingKeys: String, CodingKey { case id, name, address, enabled, settings }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        settings = try container.decodeIfPresent(MonitorSettings.self, forKey: .settings) ?? MonitorSettings()
    }

    public var displayName: String { name.isEmpty ? address : name }

    public var url: URL? {
        guard let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func normalized() -> Endpoint {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var pollingMinutes: Double
    public var lookbackMinutes: Double
    public var timeoutSeconds: Double

    public init(pollingMinutes: Double = 10, lookbackMinutes: Double = 60, timeoutSeconds: Double = 20) {
        self.pollingMinutes = pollingMinutes
        self.lookbackMinutes = lookbackMinutes
        self.timeoutSeconds = timeoutSeconds
    }

    public var isValid: Bool {
        pollingMinutes.isFinite && (1...1440).contains(pollingMinutes)
            && lookbackMinutes.isFinite && (1...10080).contains(lookbackMinutes)
            && timeoutSeconds.isFinite && (1...120).contains(timeoutSeconds)
    }
}

public struct CheckRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var endpointID: UUID
    public var address: String
    public var checkedAt: Date
    public var isUp: Bool
    public var statusCode: Int?
    public var duration: TimeInterval
    public var detail: String

    public init(id: UUID = UUID(), endpointID: UUID, address: String, checkedAt: Date,
                isUp: Bool, statusCode: Int? = nil, duration: TimeInterval = 0, detail: String) {
        self.id = id
        self.endpointID = endpointID
        self.address = address
        self.checkedAt = checkedAt
        self.isUp = isUp
        self.statusCode = statusCode
        self.duration = duration
        self.detail = detail
    }
}

public enum OverallStatus: String, Sendable {
    case unknown, healthy, recovered, down

    public var title: String {
        switch self {
        case .unknown: return "Waiting for checks"
        case .healthy: return "All systems reachable"
        case .recovered: return "Recovered from an outage"
        case .down: return "Some URLs are down"
        }
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public var endpoints: [Endpoint]
    public var records: [CheckRecord]

    public init(endpoints: [Endpoint] = [], records: [CheckRecord] = []) {
        self.endpoints = endpoints
        self.records = records
    }

    private enum CodingKeys: String, CodingKey { case endpoints, records, settings }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacySettings = try container.decodeIfPresent(MonitorSettings.self, forKey: .settings) ?? MonitorSettings()
        var endpointContainer = try container.nestedUnkeyedContainer(forKey: .endpoints)
        var decodedEndpoints: [Endpoint] = []
        while !endpointContainer.isAtEnd {
            let endpointDecoder = try endpointContainer.superDecoder()
            var endpoint = try Endpoint(from: endpointDecoder)
            let fields = try endpointDecoder.container(keyedBy: Endpoint.CodingKeys.self)
            if !fields.contains(.settings) { endpoint.settings = legacySettings }
            decodedEndpoints.append(endpoint)
        }
        endpoints = decodedEndpoints
        records = try container.decode([CheckRecord].self, forKey: .records)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(records, forKey: .records)
    }

    public var activeEndpoints: [Endpoint] { endpoints.filter(\.enabled) }

    public func latest(for endpoint: Endpoint) -> CheckRecord? {
        records.filter { $0.endpointID == endpoint.id && $0.address == endpoint.address }
            .max { $0.checkedAt < $1.checkedAt }
    }

    public func overallStatus(at now: Date = Date()) -> OverallStatus {
        let active = activeEndpoints
        guard !active.isEmpty else { return .unknown }
        let statuses = active.map { status(for: $0, at: now) }
        if statuses.contains(.down) { return .down }
        if statuses.contains(.unknown) { return .unknown }
        return statuses.contains(.recovered) ? .recovered : .healthy
    }

    public func status(for endpoint: Endpoint, at now: Date = Date()) -> OverallStatus {
        guard endpoint.enabled, let latest = latest(for: endpoint) else { return .unknown }
        if !latest.isUp { return .down }
        let cutoff = now.addingTimeInterval(-endpoint.settings.lookbackMinutes * 60)
        if records.contains(where: {
            !$0.isUp && $0.checkedAt >= cutoff && $0.checkedAt <= now
                && $0.endpointID == endpoint.id && $0.address == endpoint.address
        }) { return .recovered }
        return .healthy
    }

    @discardableResult
    public mutating func prune(at now: Date = Date()) -> Bool {
        let count = records.count
        let cutoff = now.addingTimeInterval(-Self.retention)
        records.removeAll { $0.checkedAt < cutoff }
        return records.count != count
    }

    public func validate() throws {
        guard Set(endpoints.map(\.id)).count == endpoints.count else { throw ValidationError.duplicateIDs }
        guard endpoints.allSatisfy({ $0.settings.isValid }) else { throw ValidationError.invalidSettings }
        for endpoint in endpoints where endpoint.url == nil {
            throw ValidationError.invalidURL(endpoint.address)
        }
    }
}

public enum ValidationError: LocalizedError {
    case invalidSettings, invalidURL(String), duplicateIDs
    public var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Use a polling interval of 1–1,440 minutes, a history window of 1–10,080 minutes, and a timeout of 1–120 seconds."
        case .invalidURL(let address):
            return "Enter a full http:// or https:// URL without embedded credentials: \(address)"
        case .duplicateIDs: return "Each URL must have a unique identifier."
        }
    }
}
