import Foundation

/// Reads and writes the connection tree as JSON on disk.
public struct ConnectionDocumentStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    /// Default location: `~/Library/Application Support/SSHClientMac/connections.json`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("SSHClientMac", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    /// Loads the tree, returning an empty tree when no file exists yet.
    public func load() throws -> ConnectionTree {
        guard fileManager.fileExists(atPath: url.path) else {
            return ConnectionTree()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return ConnectionTree() }
        return try JSONDecoder().decode(ConnectionTree.self, from: data)
    }

    /// Writes the tree atomically, creating the parent directory if needed.
    public func save(_ tree: ConnectionTree) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tree)
        try data.write(to: url, options: .atomic)
    }
}
