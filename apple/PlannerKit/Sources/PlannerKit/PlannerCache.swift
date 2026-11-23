import Foundation

/// Small JSON files on disk: the last server state (for offline viewing) and
/// the ledger of task blocks the app has written to the Planner calendar.
public struct PlannerCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/Planner
    public static func standard() throws -> PlannerCache {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return PlannerCache(directory: base.appending(path: "Planner", directoryHint: .isDirectory))
    }

    public func loadState() -> AppState? { load("state.json") }
    public func saveState(_ state: AppState) throws { try save(state, "state.json") }

    public func loadLedger() -> BlockLedger { load("ledger.json") ?? BlockLedger() }
    public func saveLedger(_ ledger: BlockLedger) throws { try save(ledger, "ledger.json") }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? PlannerJSON.decoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PlannerJSON.encoder().encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
    }
}

/// Which device event holds each server task block, and where it was when last written.
/// Comparing against this is how the app notices blocks the user moved or deleted.
public struct BlockLedger: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var deviceID: String
        public var start: Date
        public var end: Date
    }

    /// Keyed by the server's event id.
    public var entries: [String: Entry] = [:]

    public init() {}
}
