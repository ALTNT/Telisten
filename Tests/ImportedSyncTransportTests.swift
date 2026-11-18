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
private actor TDLibClient {
    var chat = TestChat()
    var group = TestGroup()
    var full = TestFullGroup()
    func getChat(chatId: Int64) throws -> TestChat { chat }
    func getSupergroup(supergroupId: Int64) throws -> TestGroup { group }
    func getSupergroupFullInfo(supergroupId: Int64) throws -> TestFullGroup { full }
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
    func allowed(_ client: TDLibClient) async throws -> Bool {
        try await validateImportedSyncChannel(123, ownerID: 42, client: client)
    }
    // IMPORTED_CHANNEL_VALIDATION
}

private enum SyncPhase { case ready }
private enum UserFacingError {
    static func message(for error: Error) -> String { error.localizedDescription }
}
private actor TestSyncTransport {
    var incoming: [ImportedPlaylistSyncRecord] = []
    var uploads: [ImportedPlaylistSyncEnvelope] = []
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
    var importedPlaylists: [ImportedPlaylist] = []
    var scheduledPasses = 0
    let importedPlaylistStore: ImportedPlaylistStore
    let telegram = TestSyncTransport()
    init(directory: URL) { importedPlaylistStore = ImportedPlaylistStore(directory: directory) }
    func scheduleImportedPlaylistSync() { scheduledPasses += 1 }
    func applyImportedPlaylistSyncState(_ next: ImportedPlaylistSyncState) throws {
        let values = next.playlists(preservingLocalTracks: importedPlaylists)
        try importedPlaylistStore.saveSynchronized(values, state: next, for: localMirrorAccountID)
        importedPlaylistSyncState = next
        importedPlaylists = values
    }
    // IMPORTED_SYNC_COORDINATOR
    // IMPORTED_SYNC_ACCOUNT_CHECK
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
        print("PASS: private channel verification, concurrent local edits, upload receipts, offline outbox retention and account transitions")
    }
}
