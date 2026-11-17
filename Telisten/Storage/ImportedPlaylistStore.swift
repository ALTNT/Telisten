import Foundation

final class ImportedPlaylistStore {
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
        return (try? JSONDecoder().decode([ImportedPlaylist].self, from: data)) ?? []
    }

    func save(_ playlists: [ImportedPlaylist], for accountID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(playlists).write(to: url(for: accountID), options: .atomic)
    }
}
