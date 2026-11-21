import Foundation

// These fakes exercise production destination validation without accessing an
// account, creating a channel, uploading files or sending Telegram messages.
private struct TestChannelType: Sendable { var isChannel = true; var supergroupId: Int64 = 123 }
private enum TestChatType: Sendable { case chatTypeSupergroup(TestChannelType); case chatTypePrivate }
private struct TestChat: Sendable { var type = TestChatType.chatTypeSupergroup(TestChannelType()) }
private struct TestCreator: Sendable { var isMember = true }
private enum TestStatus: Sendable { case chatMemberStatusCreator(TestCreator); case chatMemberStatusMember }
private struct TestUsernames: Sendable { var activeUsernames: [String] = [] }
private struct TestGroup: Sendable {
    var status = TestStatus.chatMemberStatusCreator(TestCreator())
    var usernames: TestUsernames? = nil
}
private struct TestFullGroup: Sendable {
    var description = "Telisten imported playlist sync v1\nowner:42"
    var memberCount = 1
    var linkedChatId: Int64 = 0
}
private struct File: Sendable {
    var id: Int
    var size: Int64 = 0
    var expectedSize: Int64 = 0
    var local: Local
    struct Local: Sendable { var path: String; var isDownloadingCompleted = true }
}
private struct TestDocument: Sendable {
    var caption: Caption
    var document: Document
    struct Caption: Sendable { var text: String }
    struct Document: Sendable { var fileName: String; var document: File }
}
private struct Message: Sendable {
    var id: Int64
    var sendingState: Bool? = nil
    var content: Content
    enum Content: Sendable { case messageDocument(TestDocument); case messageText(Text) }
    struct Text: Sendable { var text: TestDocument.Caption }
}
private struct TestDocumentPage: Sendable {
    var messages: [Message]
    var nextFromMessageId: Int64
}
private struct TestHistory: Sendable { var messages: [Message]? }
private enum TestSearchFilter: Sendable {}
private enum ServiceError: Error { case incompleteDownload }
private enum PlaybackDiagnostics { static func log(_ message: String) {} }
private actor TDLibClient {
    var chat = TestChat()
    var group = TestGroup()
    var full = TestFullGroup()
    var documentPages: [Int64: TestDocumentPage] = [:]
    var requestedPages: [Int64] = []
    var downloadedFiles: [Int] = []
    var latest: [Message] = []
    func getChat(chatId: Int64) throws -> TestChat { chat }
    func getSupergroup(supergroupId: Int64) throws -> TestGroup { group }
    func getSupergroupFullInfo(supergroupId: Int64) throws -> TestFullGroup { full }
    func setDocumentPages(_ pages: [Int64: TestDocumentPage], latest: [Message]) {
        documentPages = pages
        self.latest = latest
    }
    func getChatHistory(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int, onlyLocal: Bool) async throws -> TestHistory {
        TestHistory(messages: latest)
    }
    func searchChatMessages(chatId: Int64, filter: TestSearchFilter?, fromMessageId: Int64, limit: Int,
                            offset: Int, query: String, senderId: Int?, topicId: Int?) throws -> TestDocumentPage {
        precondition(filter == nil && query == FavoriteSyncEnvelope.marker)
        requestedPages.append(fromMessageId)
        guard let page = documentPages[fromMessageId] else { throw ImportedPlaylistSyncError.invalidData }
        return page
    }
    func downloadFile(fileId: Int, limit: Int64, offset: Int, priority: Int, synchronous: Bool) throws -> File {
        downloadedFiles.append(fileId)
        for page in documentPages.values {
            for message in page.messages {
                if case let .messageDocument(content) = message.content, content.document.document.id == fileId {
                    return content.document.document
                }
            }
        }
        throw ServiceError.incompleteDownload
    }
    func configure(_ scenario: String) {
        chat = TestChat(); group = TestGroup(); full = TestFullGroup()
        switch scenario {
        case "public": group.usernames = TestUsernames(activeUsernames: ["public_channel"])
        case "otherOwner": group.status = .chatMemberStatusMember
        case "shared": full.memberCount = 2
        case "otherAccount": full.description = "Telisten imported playlist sync v1\nowner:99"
        case "ordinaryChannel": full.description = "A playlist called Telisten Sync"
        case "linked": full.linkedChatId = 456
        case "privateChat": chat.type = .chatTypePrivate
        default: break
        }
    }
}
private actor SyncValidationHarness {
    private let client = TDLibClient()
    func documentClient() -> TDLibClient { client }
    private func requireReadyClient() async throws -> TDLibClient { client }
    private func checkImportedSyncAccount(_ expected: String, client: TDLibClient) throws {
        guard expected == "one", self.client === client else { throw ImportedPlaylistSyncError.accountChanged }
    }
    func allowed(_ client: TDLibClient) async throws -> Bool {
        try await validateImportedSyncChannel(123, ownerID: 42, client: client)
    }
    // IMPORTED_CHANNEL_VALIDATION
    // FAVORITE_DOCUMENT_TRANSPORT
}

private enum SyncPhase { case ready }
private enum UserFacingError {
    static func message(for error: Error) -> String { error.localizedDescription }
}
private actor TestSyncTransport {
    var incoming: [ImportedPlaylistSyncRecord] = []
    var incomingFavorites: [FavoriteSyncRecord] = []
    var uploads: [ImportedPlaylistSyncEnvelope] = []
    var favoriteUploads: [FavoriteSyncEnvelope] = []
    var sources: [String: Track] = [:]
    var favoritePullCursors: [Int64] = []
    var failUploads = false
    var isPushing = false
    func setup(incoming: [ImportedPlaylistSyncRecord] = [], failUploads: Bool = false) {
        self.incoming = incoming
        self.failUploads = failUploads
    }
    func prepareImportedPlaylistSync(expectedAccountID: String, expectedOwnerID: Int64?, createIfMissing: Bool) throws -> ImportedPlaylistSyncLocation {
        ImportedPlaylistSyncLocation(ownerUserID: 42, chatIDs: [-100], uploadChatID: -100)
    }
    func pullImportedPlaylistSync(chatID: Int64, after: Int64, ownerID: Int64, expectedAccountID: String) async throws -> ImportedPlaylistSyncPull {
        // Deliberately return after cancellation to test the account/token guard.
        try? await Task.sleep(for: .milliseconds(40))
        return ImportedPlaylistSyncPull(records: incoming, lastMessageID: 100)
    }
    func pushImportedPlaylistSync(_ envelope: ImportedPlaylistSyncEnvelope, chatID: Int64, expectedAccountID: String) async throws {
        isPushing = true
        defer { isPushing = false }
        try await Task.sleep(for: .milliseconds(80))
        if failUploads { throw ImportedPlaylistSyncError.sendUnconfirmed }
        uploads.append(envelope)
    }
    func setupFavorites(_ records: [FavoriteSyncRecord], tracks: [Track] = []) {
        incomingFavorites = records
        sources = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            ImportedAudioSource(track).favoriteKey.map { ($0, track) }
        })
    }
    func pullFavoriteSync(chatID: Int64, after: Int64, ownerID: Int64, expectedAccountID: String) async throws -> FavoriteSyncPull {
        favoritePullCursors.append(after)
        try? await Task.sleep(for: .milliseconds(40))
        return FavoriteSyncPull(records: incomingFavorites, lastMessageID: 101)
    }
    func pushFavoriteSync(_ envelope: FavoriteSyncEnvelope, chatID: Int64, expectedAccountID: String) async throws {
        isPushing = true
        defer { isPushing = false }
        try await Task.sleep(for: .milliseconds(80))
        if failUploads { throw ImportedPlaylistSyncError.sendUnconfirmed }
        favoriteUploads.append(envelope)
    }
    func restoreImportedAudioSource(_ source: ImportedAudioSource, expectedAccountID: String) async throws -> Track? {
        source.favoriteKey.flatMap { sources[$0] }
    }
}
@MainActor
private final class SyncCoordinatorHarness {
    var importedPlaylistSyncEnabled = true
    var isDemo = false
    var isAddingAccount = false
    var phase = SyncPhase.ready
    var activeAccountID: String? = "one"
    var localMirrorAccountID: String { activeAccountID ?? "local" }
    var importedSyncStorageIsValid = true
    var importedSyncTask: Task<Void, Never>?
    var importedSyncOperationID: UUID?
    var importedSyncNeedsAnotherPass = false
    var isSyncingImportedPlaylists = false
    var importedPlaylistSyncError: String?
    var importedPlaylistSyncState = ImportedPlaylistSyncState()
    var favoriteSyncState: FavoriteSyncState? = FavoriteSyncState()
    var favoriteSyncEnabled = false
    var favoriteSyncError: String?
    var favorites: Set<String> = []
    var knownTracks: [String: Track] = [:]
    var tracks: [Track] = []
    enum Selection { case favorites }
    var selected: Selection?
    var searchText = ""
    var importedPlaylists: [ImportedPlaylist] = []
    var scheduledPasses = 0
    let importedPlaylistStore: ImportedPlaylistStore
    let telegram = TestSyncTransport()
    init(directory: URL) { importedPlaylistStore = ImportedPlaylistStore(directory: directory) }
    func scheduleImportedPlaylistSync() { scheduledPasses += 1 }
    func persistLibrary() {}
    func sameDownloadedTrack(_ first: Track, _ second: Track) -> Bool { first.deduplicationID == second.deduplicationID }
    func matchesSearch(_ track: Track, query: String) -> Bool { query.isEmpty || track.title.contains(query) }
    func removeFavorite(_ track: Track) {
        precondition(recordFavoriteChanges(removing: [track]))
        favorites.remove(track.id)
    }
    func addFavorite(_ track: Track) {
        knownTracks[track.id] = track
        precondition(recordFavoriteChanges(adding: [track]))
        favorites.insert(track.id)
    }
    func applyImportedPlaylistSyncState(_ next: ImportedPlaylistSyncState) throws {
        let values = next.playlists(preservingLocalTracks: importedPlaylists)
        try importedPlaylistStore.saveSynchronized(values, state: next, for: localMirrorAccountID)
        importedPlaylistSyncState = next
        importedPlaylists = values
    }
    // IMPORTED_SYNC_COORDINATOR
    // IMPORTED_SYNC_ACCOUNT_CHECK
    // FAVORITE_SYNC_METHODS
}

@main
private enum ImportedSyncTransportTests {
    @MainActor
    static func main() async throws {
        let client = TDLibClient()
        let validator = SyncValidationHarness()
        let allowed = try await validator.allowed(client)
        precondition(allowed)
        for scenario in ["public", "otherOwner", "shared", "otherAccount", "ordinaryChannel", "linked", "privateChat"] {
            await client.configure(scenario)
            let allowed = try await validator.allowed(client)
            precondition(!allowed, "Unsafe channel was accepted: \(scenario)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ImportedPlaylistEntry(id: "1:0", songID: "1", title: "Song", artists: ["Artist"], album: "", duration: 200,
            songURL: URL(string: "https://music.163.com/song/1")!)
        let playlist = ImportedPlaylist(id: "netease:1", platform: .netease, sourceID: "1", title: "Local",
            sourceURL: URL(string: "https://music.163.com/playlist?id=1")!, expectedCount: 1, entries: [entry])
        let model = SyncCoordinatorHarness(directory: directory.appendingPathComponent("merge"))
        model.importedPlaylistSyncState.bootstrap([playlist], bot: nil)
        model.importedPlaylists = [playlist]
        var remotePlaylist = playlist
        remotePlaylist.id = "netease:2"; remotePlaylist.sourceID = "2"; remotePlaylist.title = "Remote"
        var remote = ImportedPlaylistSyncState()
        remote.record(.playlist(remotePlaylist))
        await model.telegram.setup(incoming: remote.pendingUploadRecords)
        let sync = Task { await model.syncImportedPlaylists() }
        try await Task.sleep(for: .milliseconds(10))
        var duringPull = playlist
        duringPull.id = "netease:3"; duringPull.sourceID = "3"; duringPull.title = "Added during pull"
        model.importedPlaylists.append(duringPull)
        model.importedPlaylistSyncState.record(.playlist(duringPull))
        model.importedSyncNeedsAnotherPass = true
        await sync.value
        precondition(Set(model.importedPlaylists.map(\.id)) == [playlist.id, remotePlaylist.id, duringPull.id])
        precondition(model.importedPlaylistSyncState.pending.isEmpty && !model.isSyncingImportedPlaylists)
        precondition(model.importedPlaylistSyncState.cursors["-100"] == 100)
        precondition(model.scheduledPasses == 1)
        let uploads = await model.telegram.uploads
        precondition(uploads.flatMap(\.records).contains { $0.playlistID == duringPull.id }, "An edit during pull must be uploaded")

        let receipt = SyncCoordinatorHarness(directory: directory.appendingPathComponent("receipt"))
        receipt.importedPlaylists = [playlist]
        receipt.importedPlaylistSyncState.bootstrap([playlist], bot: nil)
        let pushing = Task { await receipt.syncImportedPlaylists() }
        for _ in 0..<100 {
            if await receipt.telegram.isPushing { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        var renamed = playlist
        renamed.title = "Edited during upload"
        receipt.importedPlaylists = [renamed]
        receipt.importedPlaylistSyncState.record(.playlist(renamed))
        receipt.importedSyncNeedsAnotherPass = true
        await pushing.value
        precondition(receipt.importedPlaylistSyncState.pending.count == 1)
        precondition(receipt.importedPlaylists[0].title == renamed.title)
        let saved = try receipt.importedPlaylistStore.loadSyncState(for: "one")
        precondition(saved.pending.count == 1, "Upload receipts must not discard newer pending edits")

        let failed = SyncCoordinatorHarness(directory: directory.appendingPathComponent("failed"))
        failed.importedPlaylists = [playlist]
        failed.importedPlaylistSyncState.bootstrap([playlist], bot: nil)
        await failed.telegram.setup(failUploads: true)
        await failed.syncImportedPlaylists()
        precondition(!failed.isSyncingImportedPlaylists && failed.importedPlaylistSyncError != nil)
        precondition(failed.importedPlaylistSyncState.pending.count == 1)
        let persistedFailure = try failed.importedPlaylistStore.loadSyncState(for: "one")
        precondition(persistedFailure.pending.count == 1)

        let switched = SyncCoordinatorHarness(directory: directory.appendingPathComponent("switched"))
        await switched.telegram.setup(incoming: remote.pendingUploadRecords)
        let obsolete = Task { await switched.syncImportedPlaylists() }
        try await Task.sleep(for: .milliseconds(10))
        switched.activeAccountID = "two"
        await obsolete.value
        precondition(switched.importedPlaylists.isEmpty && switched.importedPlaylistStore.load(for: "two").isEmpty,
                     "An old account's pull must never enter the newly selected account")
        let favorites = SyncCoordinatorHarness(directory: directory.appendingPathComponent("favorites"))
        favorites.favoriteSyncEnabled = true
        favorites.importedPlaylistSyncEnabled = false
        favorites.selected = .favorites
        let legacyState = Data(#"{"didMigrate":true,"cursors":{"-100":999},"records":{},"pending":{},"tracks":{}}"#.utf8)
        favorites.favoriteSyncState = try JSONDecoder().decode(FavoriteSyncState.self, from: legacyState)
        let localTrack = Track(documentID: 100, accessHash: 0, fileReference: Data([1]), dcID: 0,
            messageID: 1, chatID: "-1000", title: "Local", artist: "Artist", fileName: "local.mp3",
            mimeType: "audio/mpeg", duration: 200, size: 100, date: Date(), remoteUniqueID: "local")
        favorites.favoriteSyncState?.documentCursors = ["-100": 999]
        favorites.favoriteSyncState?.set(localTrack, favorite: true)
        favorites.favoriteSyncState?.pending.removeAll()
        var remoteTrack = localTrack
        remoteTrack.documentID = 200
        remoteTrack.messageID = 2
        remoteTrack.remoteUniqueID = "remote"
        remoteTrack.title = "Remote"
        var removedTrack = remoteTrack
        removedTrack.documentID = 300
        removedTrack.messageID = 3
        removedTrack.remoteUniqueID = "removed"
        favorites.favorites = [localTrack.id, removedTrack.id]
        favorites.knownTracks = [localTrack.id: localTrack, removedTrack.id: removedTrack]
        var favoriteRemote = FavoriteSyncState()
        favoriteRemote.set(remoteTrack, favorite: true)
        favoriteRemote.set(removedTrack, favorite: false)
        await favorites.telegram.setupFavorites(Array(favoriteRemote.pending.values), tracks: [remoteTrack])
        await favorites.syncImportedPlaylists()
        precondition(favorites.favorites == [localTrack.id, remoteTrack.id])
        let favoriteUploads = await favorites.telegram.favoriteUploads
        precondition(Set(favoriteUploads.flatMap(\.records).map(\.key)) == ["remote:local", "remote:remote", "remote:removed"],
                     "The migration must resend acknowledged legacy records and preserve removals")
        precondition(favorites.favoriteSyncState?.didPublishTextRecords == true)
        let uploadedPlaylists = await favorites.telegram.uploads
        precondition(uploadedPlaylists.isEmpty)
        let pullCursors = await favorites.telegram.favoritePullCursors
        precondition(pullCursors == [0], "The legacy history cursor must not skip favorite documents")
        precondition(favorites.favoriteSyncState?.messageCursors?["-100"] == 101)
        precondition(favorites.favoriteSyncState?.lastSyncedAt != nil)
        precondition(Set(favorites.tracks.map(\.id)) == favorites.favorites)
        let payload = try JSONEncoder().encode(favoriteUploads[0])
        precondition(!(String(decoding: payload, as: UTF8.self).contains("fileReference")))
        precondition(!FavoriteSyncEnvelope.marker.hasPrefix(ImportedPlaylistSyncEnvelope.marker + " "))
        let payloadPath = directory.appendingPathComponent("favorite-document.json")
        try payload.write(to: payloadPath)
        let file = File(id: 41, size: Int64(payload.count), local: .init(path: payloadPath.path))
        let document = TestDocument(caption: .init(text: "\(FavoriteSyncEnvelope.marker) \(favoriteUploads[0].id)"),
            document: .init(fileName: FavoriteSyncEnvelope.filenamePrefix + "test.json", document: file))
        let unrelated = TestDocument(caption: .init(text: ImportedPlaylistSyncEnvelope.marker + " test"),
            document: .init(fileName: "telisten-playlist-sync-test.json", document: file))
        let documentClient = await validator.documentClient()
        let text = try favoriteUploads[0].encodedText()
        let decoded = try FavoriteSyncEnvelope.decodeText(text, ownerUserID: 42)
        precondition(decoded.records == favoriteUploads[0].records)
        let many = Array(repeating: favoriteUploads[0].records[0], count: 100)
        let batches = try FavoriteSyncEnvelope.textBatches(many, ownerUserID: 42)
        precondition(batches.count > 1 && batches.flatMap(\.records) == many)
        for batch in batches { _ = try batch.encodedText() }
        await documentClient.setDocumentPages([
            0: TestDocumentPage(messages: [Message(id: 100, content: .messageDocument(unrelated))], nextFromMessageId: 90),
            90: TestDocumentPage(messages: [], nextFromMessageId: 80),
            80: TestDocumentPage(messages: [Message(id: 80, content: .messageDocument(document))], nextFromMessageId: 10)
        ], latest: [Message(id: 95, content: .messageText(.init(text: .init(text: text))))])
        let documentPull = try await validator.pullFavoriteSync(chatID: 123, after: 10, ownerID: 42, expectedAccountID: "one")
        let pages = await documentClient.requestedPages
        let downloads = await documentClient.downloadedFiles
        precondition(documentPull.records == favoriteUploads[0].records + decoded.records && documentPull.lastMessageID == 95)
        precondition(pages == [0, 90, 80] && downloads == [41],
                     "Read past unrelated and empty pages without using them to advance the favorite cursor")

        favorites.removeFavorite(localTrack)
        await favorites.telegram.setup(failUploads: true)
        await favorites.syncImportedPlaylists()
        precondition(favorites.favoriteSyncError != nil)
        let offline = try favorites.importedPlaylistStore.loadFavoriteSyncState(for: "one")
        precondition(offline.pending["remote:local"]?.revision == 2 && offline.pending["remote:local"]?.source == nil)
        let otherAccount = try favorites.importedPlaylistStore.loadFavoriteSyncState(for: "two")
        precondition(otherAccount.records.isEmpty)
        await favorites.telegram.setup()
        await favorites.syncImportedPlaylists()
        precondition(favorites.favoriteSyncState?.pending.isEmpty == true && favorites.favoriteSyncError == nil)
        var receiver = FavoriteSyncState()
        var tombstone = offline.pending["remote:local"]!
        tombstone.revision = 1
        try receiver.merge([tombstone] + favoriteUploads[0].records)
        receiver.migrate([localTrack])
        precondition(receiver.records["remote:local"]?.source == nil && receiver.pending.isEmpty)

        favorites.addFavorite(localTrack)
        let pushingFavorite = Task { await favorites.syncImportedPlaylists() }
        for _ in 0..<100 {
            if await favorites.telegram.isPushing { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        favorites.removeFavorite(localTrack)
        await pushingFavorite.value
        let savedRemoval = try favorites.importedPlaylistStore.loadFavoriteSyncState(for: "one")
        precondition(savedRemoval.pending["remote:local"]?.revision == 4 && savedRemoval.pending["remote:local"]?.source == nil,
                     "An upload receipt must preserve a later offline removal")

        var olderTrack = localTrack
        olderTrack.remoteUniqueID = nil
        var fallback = FavoriteSyncState()
        fallback.set(olderTrack, favorite: true)
        let messageKey = ImportedAudioSource(olderTrack).favoriteKey!
        fallback.tracks[messageKey] = localTrack
        try fallback.validate()
        fallback.set(localTrack, favorite: false)
        precondition(fallback.records[messageKey]?.source == nil && fallback.records.count == 1)
        print("PASS: private channel verification, playlist and favorite migration, offline removals, upload receipts, retries and account isolation")
    }
}
