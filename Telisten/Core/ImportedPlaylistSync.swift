import Foundation

struct ImportedAudioSource: Codable, Equatable, Sendable {
    var chatID: String
    var messageID: Int64
    var remoteUniqueID: String?

    init(_ track: Track) {
        chatID = track.chatID
        messageID = track.messageID
        remoteUniqueID = track.remoteUniqueID
    }
}

struct ImportedSyncBot: Codable, Equatable, Sendable {
    var username: String
    var prefix: String
    var suffix: String

    init(_ config: SearchBotConfig) {
        username = config.normalizedBotName.lowercased()
        prefix = config.searchPrefix
        suffix = config.searchSuffix
    }

    var config: SearchBotConfig { SearchBotConfig(botName: username, searchPrefix: prefix, searchSuffix: suffix) }
}

struct ImportedPlaylistSyncRecord: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case playlist, source, bot }

    var id = UUID().uuidString
    var deviceID: String
    var revision: Int64
    var parentRevision: Int64
    var kind: Kind
    var playlistID: String?
    var generationID: String?
    var songID: String?
    // A nil playlist is a deletion tombstone. Track/file IDs are never uploaded.
    var playlist: ImportedPlaylist?
    var source: ImportedAudioSource?
    var bot: ImportedSyncBot?

    var key: String {
        switch kind {
        case .playlist: "playlist|\(playlistID ?? "")"
        case .source: "source|\(playlistID ?? "")|\(generationID ?? "")|\(songID ?? "")"
        case .bot: "bot"
        }
    }

    func isNewer(than other: Self) -> Bool {
        if revision != other.revision { return revision > other.revision }
        if deviceID != other.deviceID { return deviceID > other.deviceID }
        return id > other.id
    }

    func hasSameContent(as other: Self) -> Bool {
        var lhs = playlist
        var rhs = other.playlist
        // Import timestamps do not turn identical initial migrations into conflicts.
        lhs?.importedAt = .distantPast
        rhs?.importedAt = .distantPast
        return kind == other.kind && playlistID == other.playlistID && songID == other.songID
            && lhs == rhs && source == other.source && bot == other.bot
    }

    func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: deviceID) != nil,
              revision > 0, revision < 1_000_000_000_000_000, parentRevision >= 0, parentRevision < revision else {
            throw ImportedPlaylistSyncError.invalidData
        }
        switch kind {
        case .playlist:
            guard let playlistID, generationID == "initial" || UUID(uuidString: generationID ?? "") != nil,
                  songID == nil, source == nil, bot == nil else { throw ImportedPlaylistSyncError.invalidData }
            if let playlist {
                guard playlist.id == playlistID, playlist.entries.count <= 10_000,
                      (0...10_000).contains(playlist.expectedCount), Set(playlist.entries.map(\.id)).count == playlist.entries.count,
                      playlist.entries.allSatisfy({ entry in
                          entry.track == nil && PlaylistImportService.allowedURL(entry.songURL)
                              && !entry.songID.isEmpty && entry.songID.count <= 128
                      }), PlaylistImportService.allowedURL(playlist.sourceURL) else { throw ImportedPlaylistSyncError.invalidData }
            }
        case .source:
            guard playlistID != nil, generationID == "initial" || UUID(uuidString: generationID ?? "") != nil,
                  let songID, !songID.isEmpty, songID.count <= 128, playlist == nil, bot == nil else { throw ImportedPlaylistSyncError.invalidData }
            if let source {
                guard Int64(source.chatID) != nil, source.messageID > 0 else { throw ImportedPlaylistSyncError.invalidData }
            }
        case .bot:
            guard playlistID == nil, generationID == nil, songID == nil, playlist == nil, source == nil else {
                throw ImportedPlaylistSyncError.invalidData
            }
            if let bot {
                let name = bot.username
                guard (5...32).contains(name.count), name.hasSuffix("bot"),
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                      bot.prefix.count <= 256, bot.suffix.count <= 256,
                      !bot.prefix.contains(where: \.isNewline), !bot.suffix.contains(where: \.isNewline) else {
                    throw ImportedPlaylistSyncError.invalidData
                }
            }
        }
    }
}

struct ImportedPlaylistSyncConflict: Identifiable, Codable, Equatable, Sendable {
    var local: ImportedPlaylistSyncRecord
    var remote: ImportedPlaylistSyncRecord
    var id: String { local.key }
}

enum ImportedPlaylistSyncChange {
    case playlist(ImportedPlaylist)
    case delete(String)
    case source(playlistID: String, songID: String, source: ImportedAudioSource?)
    case bot(ImportedSyncBot?)
}

struct ImportedPlaylistSyncState: Codable, Equatable, Sendable {
    var deviceID = UUID().uuidString
    var ownerUserID: Int64?
    var clock: Int64 = 0
    var records: [String: ImportedPlaylistSyncRecord] = [:]
    var pending: [String: ImportedPlaylistSyncRecord] = [:]
    var conflicts: [String: ImportedPlaylistSyncConflict] = [:]
    var cursors: [String: Int64] = [:]
    var lastSyncedAt: Date?

    func validate() throws {
        guard UUID(uuidString: deviceID) != nil, clock >= 0, clock < 1_000_000_000_000_000,
              ownerUserID.map({ $0 > 0 }) ?? true, cursors.values.allSatisfy({ $0 >= 0 }) else {
            throw ImportedPlaylistSyncError.invalidData
        }
        for (key, record) in records {
            try record.validate()
            guard key == record.key, record.revision <= clock else { throw ImportedPlaylistSyncError.invalidData }
        }
        for (key, record) in pending {
            guard records[key] == record else { throw ImportedPlaylistSyncError.invalidData }
        }
        for (key, conflict) in conflicts {
            try conflict.local.validate()
            try conflict.remote.validate()
            guard key == conflict.local.key, key == conflict.remote.key else { throw ImportedPlaylistSyncError.invalidData }
        }
    }

    mutating func record(_ change: ImportedPlaylistSyncChange) {
        let kind: ImportedPlaylistSyncRecord.Kind
        var playlistID: String?
        var generationID: String?
        var songID: String?
        var playlist: ImportedPlaylist?
        var source: ImportedAudioSource?
        var bot: ImportedSyncBot?
        switch change {
        case let .playlist(value):
            kind = .playlist
            playlistID = value.id
            let existing = records["playlist|\(value.id)"]
            // Independent first imports share a generation. A known deletion
            // creates a new generation so old source mappings cannot reappear.
            if let existing { generationID = existing.playlist == nil ? UUID().uuidString : existing.generationID }
            else { generationID = "initial" }
            var metadata = value
            for index in metadata.entries.indices { metadata.entries[index].track = nil }
            playlist = metadata
        case let .delete(id):
            kind = .playlist
            playlistID = id
            generationID = records["playlist|\(id)"]?.generationID ?? "initial"
        case let .source(id, song, value):
            guard let parent = records["playlist|\(id)"], parent.playlist != nil else { return }
            kind = .source
            playlistID = id
            generationID = parent.generationID
            songID = song
            source = value
        case let .bot(value):
            kind = .bot
            bot = value
        }
        var record = ImportedPlaylistSyncRecord(deviceID: deviceID, revision: clock + 1, parentRevision: 0,
            kind: kind, playlistID: playlistID, generationID: generationID, songID: songID,
            playlist: playlist, source: source, bot: bot)
        let previous = records[record.key]
        if let previous, previous.hasSameContent(as: record), previous.generationID == record.generationID { return }
        clock += 1
        record.parentRevision = previous?.revision ?? 0
        records[record.key] = record
        pending[record.key] = record
        conflicts[record.key] = nil
    }

    mutating func bootstrap(_ playlists: [ImportedPlaylist], bot: ImportedSyncBot?) {
        for playlist in playlists where records["playlist|\(playlist.id)"] == nil {
            record(.playlist(playlist))
            for entry in playlist.entries {
                if let track = entry.track {
                    record(.source(playlistID: playlist.id, songID: entry.songID, source: ImportedAudioSource(track)))
                }
            }
        }
        if records["bot"] == nil, let bot { record(.bot(bot)) }
    }

    mutating func merge(_ incoming: [ImportedPlaylistSyncRecord]) throws {
        for record in incoming { try record.validate() }
        let receivedIDs = Set(incoming.map(\.id))
        // A crash after sending but before saving the receipt must not resend it.
        pending = pending.filter { !receivedIDs.contains($0.value.id) }
        var newest: [String: ImportedPlaylistSyncRecord] = [:]
        for record in incoming {
            clock = max(clock, record.revision)
            if newest[record.key].map({ record.isNewer(than: $0) }) ?? true { newest[record.key] = record }
        }
        // Establish playlist generations before merging their source records.
        for remote in newest.values.sorted(by: { ($0.kind == .playlist ? 0 : 1, $0.key) < ($1.kind == .playlist ? 0 : 1, $1.key) }) {
            let key = remote.key
            if let local = pending[key] {
                // An old channel/replayed batch may contain the same payload
                // as an intentional offline revert. It is not its upload receipt.
                if remote.revision <= local.parentRevision { continue }
                if local.hasSameContent(as: remote) {
                    records[key] = remote
                    pending[key] = nil
                } else if remote.revision > local.parentRevision && remote.id != local.id {
                    // Keep the offline draft for an explicit choice. It is not
                    // uploaded over a concurrently edited/deleted remote value.
                    conflicts[key] = ImportedPlaylistSyncConflict(local: local, remote: remote)
                    records[key] = remote
                    pending[key] = nil
                }
            } else if records[key].map({ remote.isNewer(than: $0) }) ?? true {
                records[key] = remote
                if conflicts[key] != nil { conflicts[key]?.remote = remote }
            }
        }
        pending = pending.filter { _, record in
            guard record.kind == .source, let id = record.playlistID else { return true }
            let parent = records["playlist|\(id)"]
            let draft = conflicts["playlist|\(id)"]?.local
            return (parent?.playlist != nil && parent?.generationID == record.generationID)
                || (draft?.playlist != nil && draft?.generationID == record.generationID)
        }
    }

    var pendingUploadRecords: [ImportedPlaylistSyncRecord] {
        pending.values.filter { record in
            guard record.kind == .source, let id = record.playlistID else { return true }
            let parent = records["playlist|\(id)"]
            return parent?.playlist != nil && parent?.generationID == record.generationID
        }.sorted { $0.key < $1.key }
    }

    mutating func acknowledge(_ ids: Set<String>) {
        pending = pending.filter { !ids.contains($0.value.id) }
    }

    mutating func resolve(_ key: String, keepingLocal: Bool) {
        guard let conflict = conflicts.removeValue(forKey: key) else { return }
        if keepingLocal {
            var record = conflict.local
            clock += 1
            record.id = UUID().uuidString
            record.deviceID = deviceID
            record.revision = clock
            record.parentRevision = records[key]?.revision ?? 0
            records[key] = record
            pending[key] = record
        }
    }

    func source(playlistID: String, songID: String) -> ImportedAudioSource? {
        guard let parent = records["playlist|\(playlistID)"], parent.playlist != nil,
              let generation = parent.generationID else { return nil }
        return records["source|\(playlistID)|\(generation)|\(songID)"]?.source
    }

    func playlists(preservingLocalTracks local: [ImportedPlaylist]) -> [ImportedPlaylist] {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.values.compactMap { record -> ImportedPlaylist? in
            guard record.kind == .playlist, var playlist = record.playlist else { return nil }
            let tracks = Dictionary((localByID[playlist.id]?.entries ?? []).compactMap { entry in
                entry.track.map { (entry.songID, $0) }
            }, uniquingKeysWith: { first, _ in first })
            for index in playlist.entries.indices {
                let songID = playlist.entries[index].songID
                if let track = tracks[songID], source(playlistID: playlist.id, songID: songID) == ImportedAudioSource(track) {
                    playlist.entries[index].track = track
                }
            }
            return playlist
        }.sorted {
            if $0.importedAt != $1.importedAt { return $0.importedAt < $1.importedAt }
            return $0.id < $1.id
        }
    }
}

struct ImportedPlaylistSyncEnvelope: Codable, Sendable {
    static let marker = "#TelistenImportedPlaylistsV1"
    static let maximumBytes = 8 * 1_024 * 1_024
    var version = 1
    var id = UUID().uuidString
    var ownerUserID: Int64
    var records: [ImportedPlaylistSyncRecord]

    func encoded() throws -> Data {
        guard ownerUserID > 0 else { throw ImportedPlaylistSyncError.invalidData }
        for record in records { try record.validate() }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw ImportedPlaylistSyncError.tooLarge }
        return data
    }

    static func decode(_ data: Data, ownerUserID: Int64) throws -> Self {
        guard data.count <= maximumBytes else { throw ImportedPlaylistSyncError.tooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.ownerUserID == ownerUserID, UUID(uuidString: result.id) != nil,
              result.records.count <= 20_000 else { throw ImportedPlaylistSyncError.invalidData }
        for record in result.records { try record.validate() }
        return result
    }

    static func batches(_ records: [ImportedPlaylistSyncRecord], ownerUserID: Int64) throws -> [Self] {
        var result: [Self] = []
        var current: [ImportedPlaylistSyncRecord] = []
        var size = 1_024
        for record in records {
            let bytes = try JSONEncoder().encode(record).count + 1
            guard bytes + 1_024 <= maximumBytes else { throw ImportedPlaylistSyncError.tooLarge }
            if size + bytes > maximumBytes || current.count >= 10_000 {
                result.append(Self(ownerUserID: ownerUserID, records: current))
                current = []
                size = 1_024
            }
            current.append(record)
            size += bytes
        }
        if !current.isEmpty { result.append(Self(ownerUserID: ownerUserID, records: current)) }
        return result
    }
}

struct ImportedPlaylistSyncLocation: Sendable {
    var ownerUserID: Int64
    var chatIDs: [Int64]
    var uploadChatID: Int64
}

struct ImportedPlaylistSyncPull: Sendable {
    var records: [ImportedPlaylistSyncRecord]
    var lastMessageID: Int64
}

enum ImportedPlaylistSyncError: LocalizedError {
    case invalidData
    case tooLarge
    case unsafeChannel
    case accountChanged
    case sendUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidData: "Playlist sync data could not be verified. Local changes have been kept."
        case .tooLarge: "The playlist sync file is too large. Local changes have been kept."
        case .unsafeChannel: "Playlist sync requires a private channel owned only by this Telegram account."
        case .accountChanged: "The Telegram account changed during playlist sync. Please try again."
        case .sendUnconfirmed: "Telegram has not confirmed the sync upload. Local changes will be retried later."
        }
    }
}
