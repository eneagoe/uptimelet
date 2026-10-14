import Foundation

public struct StateStore {
    public let fileURL: URL
    private let legacyFileURL: URL?

    public init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    public static var applicationStore: StateStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = support.appendingPathComponent("Uptimelet/state.json")
        let legacy = support.appendingPathComponent("StatusCheck/state.json")
        return StateStore(fileURL: file, legacyFileURL: legacy)
    }

    public func load(at now: Date = Date()) throws -> AppState {
        let source: URL
        if FileManager.default.fileExists(atPath: fileURL.path) { source = fileURL }
        else if let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) { source = legacyFileURL }
        else { return AppState() }
        var state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: source))
        try state.validate()
        let pruned = state.prune(at: now)
        if pruned || source != fileURL { try save(state, at: now) }
        return state
    }

    public func save(_ state: AppState, at now: Date = Date()) throws {
        var retained = state
        retained.prune(at: now)
        try retained.validate()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(retained).write(to: fileURL, options: [.atomic])
    }
}
