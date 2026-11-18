import Foundation

@main
enum ImportedPlaylistSyncTests {
    static func main() throws {
        let track = Track(documentID: 9001, accessHash: 123, fileReference: Data([1, 2]), dcID: 0,
            messageID: 123456, chatID: "42", title: "Song", artist: "Artist", fileName: "Song.flac",
            mimeType: "audio/flac", duration: 200, size: 500, date: Date(), upvoteCount: nil, didUpvote: nil,
            remoteUniqueID: "stable-audio")
        var entry = ImportedPlaylistEntry(id: "123:0", songID: "123", title: "Song", artists: ["Artist"], album: "Album",
            duration: 200, songURL: URL(string: "https://music.163.com/song/123")!, track: track)
        let playlist = ImportedPlaylist(id: "netease:1", platform: .netease, sourceID: "1", title: "List",
            sourceURL: URL(string: "https://music.163.com/playlist?id=1")!, expectedCount: 1, entries: [entry])
        var first = ImportedPlaylistSyncState()
        first.bootstrap([playlist], bot: ImportedSyncBot(SearchBotConfig(botName: "MusicBot")))
        precondition(first.pending.count == 3)
        let envelope = ImportedPlaylistSyncEnvelope(ownerUserID: 42, records: first.pendingUploadRecords)
        let encoded = try envelope.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(!text.contains("documentID") && !text.contains("fileReference") && !text.contains("accessHash"),
                     "Device-local audio identifiers and credentials must never enter cloud snapshots")
        let decoded = try ImportedPlaylistSyncEnvelope.decode(encoded, ownerUserID: 42)
        do {
            _ = try ImportedPlaylistSyncEnvelope.decode(encoded, ownerUserID: 99)
            preconditionFailure("Another account's sync file must be rejected")
        } catch ImportedPlaylistSyncError.invalidData {}
        var second = ImportedPlaylistSyncState()
        try second.merge(decoded.records)
        first.acknowledge(Set(decoded.records.map(\.id)))
        precondition(first.pending.isEmpty && second.pending.isEmpty)
        let restored = second.playlists(preservingLocalTracks: [])
        precondition(restored.count == 1 && restored[0].entries[0].track == nil)
        precondition(second.source(playlistID: playlist.id, songID: entry.songID) == ImportedAudioSource(track))
        precondition(second.records["bot"]?.bot?.username == "musicbot")
        try second.merge(decoded.records)
        precondition(second.records.count == 3, "Repeated downloads must be idempotent")

        // Independent song mappings must merge without replacing the song list.
        var changedTrack = track
        changedTrack.messageID = 234567
        changedTrack.remoteUniqueID = "replacement-audio"
        first.record(.source(playlistID: playlist.id, songID: entry.songID, source: ImportedAudioSource(changedTrack)))
        second.record(.source(playlistID: playlist.id, songID: "456", source: ImportedAudioSource(track)))
        let left = first.pendingUploadRecords
        let right = second.pendingUploadRecords
        try first.merge(right)
        try second.merge(left)
        precondition(first.conflicts.isEmpty && second.conflicts.isEmpty)
        precondition(first.source(playlistID: playlist.id, songID: "456") == ImportedAudioSource(track))
        precondition(second.source(playlistID: playlist.id, songID: entry.songID) == ImportedAudioSource(changedTrack))
        precondition(second.playlists(preservingLocalTracks: [playlist])[0].entries[0].track == nil,
                     "A changed remote mapping must invalidate the old device-local Track")

        // An upload receipt for an earlier edit cannot acknowledge a later edit.
        let oldReceipt = Set(first.pending.values.map(\.id))
        first.record(.source(playlistID: playlist.id, songID: entry.songID, source: nil))
        first.acknowledge(oldReceipt)
        precondition(first.pending.count == 1)

        var reverted = ImportedPlaylistSyncState()
        try reverted.merge(decoded.records)
        let oldPlaylistRecord = reverted.records["playlist|\(playlist.id)"]!
        var interim = playlist
        interim.title = "Interim name"
        reverted.record(.playlist(interim))
        reverted.acknowledge(Set(reverted.pending.values.map(\.id)))
        reverted.record(.playlist(playlist))
        let revertID = reverted.pending[oldPlaylistRecord.key]!.id
        try reverted.merge([oldPlaylistRecord])
        precondition(reverted.pending[oldPlaylistRecord.key]?.id == revertID,
                     "An ancient equal payload is not proof that an offline revert was uploaded")

        var deleted = ImportedPlaylistSyncState()
        try deleted.merge(decoded.records)
        var offline = deleted
        offline.deviceID = UUID().uuidString
        deleted.record(.delete(playlist.id))
        var renamed = playlist
        renamed.title = "Offline title"
        offline.record(.playlist(renamed))
        try offline.merge(deleted.pendingUploadRecords)
        precondition(offline.playlists(preservingLocalTracks: [renamed]).isEmpty,
                     "An old device must not silently resurrect a deleted playlist")
        precondition(offline.conflicts["playlist|\(playlist.id)"]?.local.playlist?.title == "Offline title")
        offline.resolve("playlist|\(playlist.id)", keepingLocal: true)
        precondition(offline.playlists(preservingLocalTracks: [renamed])[0].title == "Offline title")
        try deleted.merge(offline.pendingUploadRecords)
        precondition(deleted.conflicts.count == 1, "A concurrent unacknowledged local deletion must be preserved for a choice")
        deleted.resolve("playlist|\(playlist.id)", keepingLocal: false)
        precondition(deleted.playlists(preservingLocalTracks: []).count == 1)

        // A new import after a known deletion has a new generation. Old audio
        // mappings are not inherited unless the user explicitly restores them.
        var recreated = ImportedPlaylistSyncState()
        try recreated.merge(decoded.records)
        recreated.record(.delete(playlist.id))
        entry.track = nil
        var newPlaylist = playlist
        newPlaylist.entries = [entry]
        recreated.record(.playlist(newPlaylist))
        precondition(recreated.source(playlistID: playlist.id, songID: entry.songID) == nil)

        // Existing copies imported independently on two devices should converge
        // without losing a locally confirmed source solely due to generation IDs.
        var migration = ImportedPlaylistSyncState()
        migration.bootstrap([playlist], bot: nil)
        var cloud = ImportedPlaylistSyncState()
        cloud.bootstrap([newPlaylist], bot: nil)
        try migration.merge(cloud.pendingUploadRecords)
        precondition(migration.conflicts.isEmpty)
        precondition(migration.source(playlistID: playlist.id, songID: entry.songID) == ImportedAudioSource(track))
        precondition(migration.playlists(preservingLocalTracks: [playlist])[0].entries[0].track == track)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedPlaylistStore(directory: directory)
        try store.saveSynchronized([playlist], state: offline, for: "first")
        let savedState = try store.loadSyncState(for: "first")
        precondition(savedState == offline)
        precondition(store.load(for: "first") == [playlist])
        let otherAccount = try store.loadSyncState(for: "second")
        precondition(otherAccount.pending.isEmpty)
        let legacyKey = Data("legacy".utf8).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode([playlist]).write(to: directory.appendingPathComponent("\(legacyKey).json"))
        precondition(store.load(for: "legacy") == [playlist])
        let legacyState = try store.loadSyncState(for: "legacy")
        precondition(legacyState.records.isEmpty)
        try Data("broken sync file".utf8).write(to: directory.appendingPathComponent("\(legacyKey).json"))
        do {
            _ = try store.loadSyncState(for: "legacy")
            preconditionFailure("Corrupt outboxes must not be silently replaced with empty state")
        } catch {}
        for batch in try ImportedPlaylistSyncEnvelope.batches(decoded.records, ownerUserID: 42) {
            _ = try ImportedPlaylistSyncEnvelope.decode(batch.encoded(), ownerUserID: 42)
        }
        print("PASS: sync portability, account isolation, idempotency, independent mappings, receipt races, deletion conflicts, generations and atomic migration")
    }
}
