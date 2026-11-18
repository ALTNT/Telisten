import Foundation

private enum UserFacingError {
    static func message(for error: Error) -> String { error.localizedDescription }
}
private enum PlaybackDiagnostics {
    static func log(_ event: String, error: Error? = nil) {}
}

// Minimal transport fakes exercise the actual production polling method without
// sending Telegram messages or waiting for its two-minute timeout.
private struct FormattedText: Sendable {
    var entities: [Int]
    var text: String
}
private struct InputMessageText: Sendable {
    var clearDraft: Bool
    var linkPreviewOptions: Int?
    var text: FormattedText
}
private enum ImportedTestInputContent: Sendable {
    case inputMessageText(InputMessageText)
}
private struct ImportedTestReply: Sendable {
    var chatId: Int64
    var messageId: Int64
}
private enum ImportedTestReplyTo: Sendable {
    case messageReplyToMessage(ImportedTestReply)
}
private struct ImportedTestDocument: Sendable { var mimeType = "audio/flac" }
private struct ImportedTestMessageDocument: Sendable { var document = ImportedTestDocument() }
private enum ImportedTestContent: Sendable { case other; case messageDocument(ImportedTestMessageDocument) }
private struct ImportedTestMessage: Sendable {
    var id: Int64
    var isOutgoing = false
    var sendingState: Int? = nil
    var replyTo: ImportedTestReplyTo? = nil
    var text = ""
    var track: Track? = nil
    var content = ImportedTestContent.other
}
private enum TelegramMapping {
    static func text(from message: ImportedTestMessage) -> String { message.text }
    static func track(from message: ImportedTestMessage) -> Track? { message.track }
}
private actor ImportedTestClient {
    var messages: [ImportedTestMessage] = []
    var requestCount = 0
    var returnAudioImmediately = false
    let track: Track
    init(track: Track) { self.track = track }
    func history() -> [ImportedTestMessage] { messages }
    func useImmediateAudio() { returnAudioImmediately = true }
    func sendMessage(chatId: Int64, inputMessageContent: ImportedTestInputContent,
                     options: Int?, replyMarkup: Int?, replyTo: Int?, topicId: Int?) throws -> ImportedTestMessage {
        requestCount += 1
        let commandID = Int64(requestCount * 10)
        let command: ImportedTestMessage
        switch inputMessageContent {
        case let .inputMessageText(content): command = ImportedTestMessage(id: commandID, isOutgoing: true, text: content.text.text)
        }
        messages.append(command)
        if requestCount == 1 && !returnAudioImmediately {
            let progressID = commandID + 1
            messages.append(ImportedTestMessage(id: progressID,
                replyTo: .messageReplyToMessage(ImportedTestReply(chatId: chatId, messageId: commandID)), text: "Downloading…"))
            messages.append(ImportedTestMessage(id: commandID + 2,
                replyTo: .messageReplyToMessage(ImportedTestReply(chatId: chatId, messageId: progressID)),
                text: "所念皆星河 (Inst.)\nAlbum: 所念皆星河 (Instrumental)\nThis track is currently unavailable, please try again later."))
        } else {
            // A late error replying to the old command must be ignored while
            // resolving the next song, even though it is a new message.
            messages.append(ImportedTestMessage(id: commandID + 1,
                replyTo: .messageReplyToMessage(ImportedTestReply(chatId: chatId, messageId: 10)), text: "Song not found."))
            messages.append(ImportedTestMessage(id: commandID + 2,
                replyTo: .messageReplyToMessage(ImportedTestReply(chatId: chatId, messageId: commandID)), track: track))
        }
        return command
    }
}
private actor ImportedResolverHarness {
    enum ServiceError: Error { case telegram(String) }
    var accountID = "one"
    var isResolvingImportedMusic = false
    var importedMusicIsForeground = true
    var importedMusicWaitBudget: ImportedMusicWaitBudget?
    var importedMusicRetryAfter: [String: Date] = [:]
    let client: ImportedTestClient
    init(track: Track) { client = ImportedTestClient(track: track) }
    func expireWaitForTest() -> Bool {
        importedMusicWaitBudget?.hasExpired(now: Date().addingTimeInterval(121)) ?? false
    }
    func resolveSearchBot(_ config: SearchBotConfig) async throws -> MusicChat {
        MusicChat(id: "u:1", peerID: 1, accessHash: nil, kind: .user, title: "Bot", username: config.botName)
    }
    func requireReadyClient() async throws -> ImportedTestClient { client }
    func botHistoryMessages(client: ImportedTestClient, chatID: Int64, limit: Int) async throws -> [ImportedTestMessage] {
        await client.history()
    }

    // IMPORTED_RESOLVER_METHOD
}

@MainActor
private final class ImportedTestPlayer {
    var track: Track?
    var currentTime: TimeInterval = 0
    func reset() { track = nil }
}

private actor ImportedTestTelegram {
    let track: Track
    var requests = 0
    var restoreRequests = 0
    var unavailableSongIDs: Set<String> = []
    init(track: Track) { self.track = track }
    func setUnavailableSongs(_ ids: Set<String>) { unavailableSongIDs = ids }
    func restoreImportedAudioSource(_ source: ImportedAudioSource, expectedAccountID: String) throws -> Track? {
        restoreRequests += 1
        return track
    }
    func resolveImportedMusic(_ entry: ImportedPlaylistEntry, using config: SearchBotConfig) async throws -> Track {
        requests += 1
        try await Task.sleep(for: .milliseconds(80))
        if unavailableSongIDs.contains(entry.songID) {
            throw ImportedMusicError.unavailable("This track is currently unavailable, please try again later.")
        }
        return track
    }
    func botSearchHistory(config: SearchBotConfig, limit: Int32) throws -> [BotSearchMessage] { [] }
}

@MainActor
private final class ImportedPlaybackHarness {
    var importedPlaylists: [ImportedPlaylist] = []
    var importedPlaylistErrors: [String: [String: String]] = [:]
    var importedPlaylistSyncState = ImportedPlaylistSyncState()
    var importedSyncStorageIsValid = true
    var searchBots = [SearchBotConfig(botName: "TestMusicBot")]
    var importedPlaylistBotID: UUID?
    var resolvingImportedEntryID: String?
    var playingImportedPlaylistID: String?
    var playingImportedEntryID: String?
    var activeAccountID: String? = "one"
    var localMirrorAccountID: String { activeAccountID ?? "local" }
    var errorMessage: String?
    var isBotSearching = false
    var isStartingImportedTrack = false
    var importedPlaybackTask: Task<Void, Never>?
    var importedPlaybackOperationID: UUID?
    var playbackTask: Task<Void, Never>?
    var queue: [Track] = []
    var currentQueueIndex: Int?
    var playbackMode: PlaybackMode = .order
    let player = ImportedTestPlayer()
    let importedPlaylistStore: ImportedPlaylistStore
    let telegram: ImportedTestTelegram

    init(directory: URL, track: Track) {
        importedPlaylistStore = ImportedPlaylistStore(directory: directory)
        telegram = ImportedTestTelegram(track: track)
        importedPlaylistBotID = searchBots.first!.id
    }
    func install(_ tracks: [Track]) {}
    func scheduleImportedPlaylistSync() {}
    func play(_ track: Track, from list: [Track]?) {
        if !isStartingImportedTrack { cancelImportedPlayback() }
        player.track = track
        queue = list ?? [track]
    }

    // IMPORTED_PLAYBACK_METHODS
    // IMPORTED_SAVE_METHOD
}

@main
private enum ImportedPlaybackTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = Track(documentID: 1, accessHash: 0, fileReference: Data(), dcID: 2, messageID: 3, chatID: "1",
            title: "Song", artist: "Artist", fileName: "Song.flac", mimeType: "audio/flac", duration: 200, size: 500,
            date: Date(), upvoteCount: nil, didUpvote: nil)
        let entry = ImportedPlaylistEntry(id: "1:0", songID: "1", title: "Song", artists: ["Artist"], album: "", duration: 200,
            songURL: URL(string: "https://music.163.com/song/1")!)
        let playlist = ImportedPlaylist(id: "netease:1", platform: .netease, sourceID: "1", title: "List",
            sourceURL: URL(string: "https://music.163.com/playlist?id=1")!, expectedCount: 1, entries: [entry])
        let model = ImportedPlaybackHarness(directory: directory, track: track)
        precondition(model.saveImportedPlaylist(playlist))
        var requestCount = await model.telegram.requests
        precondition(requestCount == 0, "Importing must not request audio")

        model.playImportedEntry(entry.id, in: playlist.id)
        let pending = model.importedPlaybackTask!
        model.playImportedEntry(entry.id, in: playlist.id)
        await pending.value
        requestCount = await model.telegram.requests
        precondition(requestCount == 1, "Repeated taps must not create duplicate bot requests")
        precondition(model.player.track == track && model.resolvingImportedEntryID == nil)
        precondition(model.importedPlaylistStore.load(for: "one")[0].entries[0].track == track)

        model.playImportedEntry(entry.id, in: playlist.id)
        await model.importedPlaybackTask?.value
        requestCount = await model.telegram.requests
        precondition(requestCount == 1, "Matched sources must be reused")

        model.clearImportedSource(playlistID: playlist.id, entryID: entry.id)
        model.playImportedEntry(entry.id, in: playlist.id)
        let cancelled = model.importedPlaybackTask!
        model.cancelImportedPlayback()
        await cancelled.value
        precondition(model.player.track == nil && model.importedPlaylists[0].entries[0].track == nil,
                     "Cancelled requests must neither start playback nor associate audio")

        model.playImportedEntry(entry.id, in: playlist.id)
        let oldAccountTask = model.importedPlaybackTask!
        model.activeAccountID = "two"
        await oldAccountTask.value
        precondition(model.player.track == nil && model.importedPlaylistStore.load(for: "two").isEmpty,
                     "An account switch must discard a late response")
        model.cancelImportedPlayback()
        model.activeAccountID = "one"

        model.isBotSearching = true
        model.playImportedEntry(entry.id, in: playlist.id)
        precondition(model.importedPlaybackTask == nil && model.errorMessage != nil)
        model.isBotSearching = false
        model.errorMessage = nil
        model.importedPlaylistBotID = nil
        model.playImportedEntry(entry.id, in: playlist.id)
        precondition(model.importedPlaybackTask == nil && model.errorMessage != nil)

        let unavailableModel = ImportedPlaybackHarness(directory: directory.appendingPathComponent("unavailable"), track: track)
        var twoSongs = playlist
        var secondEntry = entry
        secondEntry.id = "2:1"
        secondEntry.songID = "2"
        twoSongs.entries.append(secondEntry)
        twoSongs.expectedCount = 2
        precondition(unavailableModel.saveImportedPlaylist(twoSongs))
        await unavailableModel.telegram.setUnavailableSongs([entry.songID])
        unavailableModel.playImportedEntry(entry.id, in: playlist.id)
        await unavailableModel.importedPlaybackTask?.value
        precondition(unavailableModel.resolvingImportedEntryID == nil && unavailableModel.importedPlaybackTask == nil,
                     "An unavailable song must release the waiting state")
        precondition(unavailableModel.playingImportedEntryID == nil && unavailableModel.player.track == nil)
        precondition(unavailableModel.importedPlaylistErrors[playlist.id]?[entry.id] != nil)
        precondition(unavailableModel.errorMessage == nil, "Expected unavailability belongs in the row, not a global error alert")
        precondition(unavailableModel.importedPlaylists[0].entries[0].track == nil)
        unavailableModel.playImportedEntry(secondEntry.id, in: playlist.id)
        await unavailableModel.importedPlaybackTask?.value
        precondition(unavailableModel.player.track == track && unavailableModel.playingImportedEntryID == secondEntry.id,
                     "A missing song must not block playback of other entries")
        await unavailableModel.telegram.setUnavailableSongs([])
        unavailableModel.playImportedEntry(entry.id, in: playlist.id)
        precondition(unavailableModel.importedPlaylistErrors[playlist.id]?[entry.id] == nil,
                     "An explicit retry clears the transient unavailable status")
        await unavailableModel.importedPlaybackTask?.value
        precondition(unavailableModel.player.track == track && unavailableModel.playingImportedEntryID == entry.id)
        let resolver = ImportedResolverHarness(track: track)
        let config = SearchBotConfig(botName: "TestMusicBot")
        do {
            _ = try await resolver.resolveImportedMusic(entry, using: config)
            preconditionFailure("A terminal unavailable reply must throw immediately")
        } catch let ImportedMusicError.unavailable(reason) {
            precondition(reason == "This track is currently unavailable, please try again later.")
        }
        let stillResolving = await resolver.isResolvingImportedMusic
        let retryDelays = await resolver.importedMusicRetryAfter
        precondition(!stillResolving && retryDelays.isEmpty,
                     "A definitive failure must release the gate without a timeout cooldown")
        let resolved = try await resolver.resolveImportedMusic(secondEntry, using: config)
        precondition(resolved == track, "The next request must succeed despite a late unavailable reply for the old command")
        let finalPoll = ImportedResolverHarness(track: track)
        await finalPoll.client.useImmediateAudio()
        let late = Task { try await finalPoll.resolveImportedMusic(entry, using: config) }
        try await Task.sleep(for: .milliseconds(100))
        let expired = await finalPoll.expireWaitForTest()
        precondition(expired)
        let recovered = try await late.value
        precondition(recovered == track, "An elapsed budget must not skip the final history check for an already-delivered file")
        let restoredModel = ImportedPlaybackHarness(directory: directory.appendingPathComponent("restored"), track: track)
        try restoredModel.importedPlaylistSyncState.merge(unavailableModel.importedPlaylistSyncState.pendingUploadRecords)
        restoredModel.importedPlaylists = restoredModel.importedPlaylistSyncState.playlists(preservingLocalTracks: [])
        restoredModel.importedPlaylistBotID = nil
        restoredModel.playImportedEntry(entry.id, in: playlist.id)
        await restoredModel.importedPlaybackTask?.value
        let restoreRequests = await restoredModel.telegram.restoreRequests
        let botRequests = await restoredModel.telegram.requests
        precondition(restoreRequests == 1 && botRequests == 0 && restoredModel.player.track == track,
                     "A new device must restore the message's own file ID without issuing another bot command")
        print("PASS: imports without requests, duplicate taps, reuse, cancellation, account switching and manual bot exclusion")
        print("PASS: unavailable replies release waiting, mark only the affected entry, allow another song and support explicit retry")
        print("PASS: production bot polling detects unavailable replies, releases its gate and ignores stale failures")
    }
}
