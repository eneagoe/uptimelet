import Foundation

public struct ConfigurationImport: Equatable, Sendable {
    public let endpoints: [Endpoint]
    public let added: Int
    public let updated: Int
    public let unchanged: Int

    public var count: Int { added + updated + unchanged }
    public var message: String {
        "Imported \(count) \(count == 1 ? "URL" : "URLs"): \(added) added, \(updated) updated, \(unchanged) unchanged."
    }
}

public enum ConfigurationTransfer {
    private struct Document: Codable {
        let format: String
        let version: Int
        let endpoints: [Endpoint]
    }
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    public static func export(_ endpoints: [Endpoint]) throws -> Data {
        let normalized = endpoints.map { $0.normalized() }
        try AppState(endpoints: normalized).validate()
        let document = Document(format: "uptimelet-urls", version: 1, endpoints: normalized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> [Endpoint] {
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.format == "uptimelet-urls" else { throw ConfigurationTransferError.invalidFile }
            guard header.version == 1 else { throw ConfigurationTransferError.unsupportedVersion(header.version) }
            let document = try decoder.decode(Document.self, from: data)
            let endpoints = document.endpoints.map { $0.normalized() }
            try AppState(endpoints: endpoints).validate()
            return endpoints
        } catch is DecodingError {
            throw ConfigurationTransferError.invalidFile
        }
    }

    public static func merge(_ imported: [Endpoint], into existing: [Endpoint]) throws -> ConfigurationImport {
        let imported = imported.map { $0.normalized() }
        let existing = existing.map { $0.normalized() }
        try AppState(endpoints: imported).validate()
        try AppState(endpoints: existing).validate()
        var result = existing
        var matchedIndices = Set<Int>()
        var usedIDs = Set(existing.map(\.id))
        var added = 0
        var updated = 0
        var unchanged = 0
        for var endpoint in imported {
            // Prefer the same exported item, then match the exact URL on another Mac.
            // Each local item is used once so intentionally repeated URLs round-trip.
            let matchingID = existing.indices.first {
                !matchedIndices.contains($0) && existing[$0].id == endpoint.id && existing[$0].address == endpoint.address
            }
            let matchingURL = matchingID ?? existing.indices.first {
                !matchedIndices.contains($0) && existing[$0].address == endpoint.address
            }
            if let index = matchingURL {
                matchedIndices.insert(index)
                endpoint.id = existing[index].id
                if endpoint == existing[index] { unchanged += 1 }
                else { updated += 1 }
                result[index] = endpoint
            } else {
                // Never attach another address to an existing URL's logs by reusing its ID.
                while usedIDs.contains(endpoint.id) { endpoint.id = UUID() }
                usedIDs.insert(endpoint.id)
                result.append(endpoint)
                added += 1
            }
        }
        return ConfigurationImport(endpoints: result, added: added, updated: updated, unchanged: unchanged)
    }
}

public enum ConfigurationTransferError: LocalizedError {
    case invalidFile, unsupportedVersion(Int), storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "This file is not a valid Uptimelet URL export. Choose a JSON file created by Export URLs."
        case .unsupportedVersion(let version): return "This export uses format version \(version). Update Uptimelet before importing it."
        case .storageUnavailable: return "Saved data could not be loaded. Resolve the storage error before importing URLs."
        }
    }
}
