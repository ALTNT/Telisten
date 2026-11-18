import Foundation

final class ImportedPlaylistStore {
    private struct Snapshot: Codable {
        var playlists: [ImportedPlaylist]
        var sync: ImportedPlaylistSyncState
    }
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Telisten/ImportedPlaylists", isDirectory: true)
    }

    private func url(for accountID: String) -> URL {
        // Encode the entire account key so it cannot become a path component.
        let key = Data(accountID.utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).json")
    }

    func load(for accountID: String) -> [ImportedPlaylist] {
        guard let data = try? Data(contentsOf: url(for: accountID)) else { return [] }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) { return snapshot.playlists }
        return (try? JSONDecoder().decode([ImportedPlaylist].self, from: data)) ?? []
    }

    func loadSyncState(for accountID: String) throws -> ImportedPlaylistSyncState {
        let path = url(for: accountID)
        guard FileManager.default.fileExists(atPath: path.path) else { return ImportedPlaylistSyncState() }
        let data = try Data(contentsOf: path)
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            try snapshot.sync.validate()
            return snapshot.sync
        }
        // Migrate the previous array format; malformed sync metadata must never
        // be treated as an empty outbox and overwrite the user's offline edits.
        _ = try JSONDecoder().decode([ImportedPlaylist].self, from: data)
        return ImportedPlaylistSyncState()
    }

    func save(_ playlists: [ImportedPlaylist], for accountID: String) throws {
        try saveSynchronized(playlists, state: loadSyncState(for: accountID), for: accountID)
    }

    func saveSynchronized(_ playlists: [ImportedPlaylist], state: ImportedPlaylistSyncState, for accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(playlists: playlists, sync: state)).write(to: url(for: accountID), options: .atomic)
    }
}
