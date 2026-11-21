import Foundation

private enum PlaybackDiagnostics {
    static func log(_ event: String, error: Error? = nil) {}
}

private final class ForegroundTestClient: @unchecked Sendable {
    let id: Int32
    var closeCount = 0
    var onClose: (@Sendable () -> Void)?
    init(id: Int32) { self.id = id }
    func close(completion: @escaping (Result<Void, Error>) -> Void) throws {
        closeCount += 1
        completion(.success(()))
        onClose?()
    }
}

private actor ForegroundConnectionHarness {
    enum ServiceError: Error { case noConnection }
    enum AuthorizationState { case authorizationStateReady }
    var replacingSession = false
    var reconnectingClient = false
    var closingClientID: Int32?
    var proxyClientReady = true
    let original = ForegroundTestClient(id: 1)
    var client: ForegroundTestClient?
    var accountID = "original"
    var authorizationState: AuthorizationState? = .authorizationStateReady
    var connectionState: String
    var reopenCount = 0
    var acceptedUpdates = 0
    // Recovery must preserve handles owned by a video that is still open.
    var mediaHandles = ["video": 42]

    init(state: String = "connectionStateConnecting") {
        client = original
        connectionState = state
    }

    func acknowledgeClose() {
        original.onClose = { [weak self] in
            Task { await self?.deliverClosed() }
        }
    }
    func deliverClosed() async {
        await receiveClientUpdate(Data(#"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateClosed"}}"#.utf8), from: 1)
    }
    func deliverUpdate(from id: Int32) async { await receiveClientUpdate(Data("{}".utf8), from: id) }
    func setState(_ state: String) { connectionState = state }
    func changeAccount() { accountID = "different" }
    func clearAuthorization() { authorizationState = nil }
    func readableLoginError(_ error: Error) -> Error { error }
    func receiveUpdate(_ data: Data) async { acceptedUpdates += 1 }
    func closeWebProxyCarriers(for clientID: Int32) async {}
    func requireReadyClient() async throws -> ForegroundTestClient {
        guard !reconnectingClient, closingClientID == nil else { throw ServiceError.noConnection }
        let opened = ForegroundTestClient(id: 2)
        client = opened
        proxyClientReady = true
        reopenCount += 1
        return opened
    }
    func openAfterLateClose() async throws { _ = try await requireReadyClient() }
    func snapshot() -> (closed: Int, opened: Int, pendingClose: Int32?, updates: Int, media: Int?) {
        (original.closeCount, reopenCount, closingClientID, acceptedUpdates, mediaHandles["video"])
    }

    // FOREGROUND_CONNECTION_METHODS
}

private actor ForegroundServiceProbe {
    func setImportedMusicForeground(_ foreground: Bool) {}
    private var calls = 0
    func hasAuthorizedSession() -> Bool { true }
    func recoverConnectionAfterStandby() throws { calls += 1 }
    func count() -> Int { calls }
}

@MainActor
private final class ForegroundProxyProbe {
    func refresh() async {}
}

@MainActor
private final class ForegroundAppHarness {
    enum Phase { case ready, connecting }
    var phase: Phase
    var backgroundedAt: Date?
    var foregroundReconnectTask: Task<Void, Never>?
    var hasCredentials = true
    var isAddingAccount = false
    var activeAccountID: String? = "original"
    let proxyController = ForegroundProxyProbe()
    let telegram = ForegroundServiceProbe()
    var downloadTasks: [String: Task<URL, Error>] = [:]
    var pendingDownloadResumeIDs: Set<String> = []
    var cachedIDs: Set<String> = []
    var resumingDownloadIDs: Set<String> = []
    var knownTracks: [String: String] = [:]
    var scheduledPlaylistSyncs = 0
    init(phase: Phase, secondsInBackground: Double) {
        self.phase = phase
        backgroundedAt = Date().addingTimeInterval(-secondsInBackground)
    }
    func persistPendingDownloadResumeIDs() {}
    func clearPendingDownloadResumeID(_ id: String) {}
    func resumePendingDownload(_ track: String, retryAfterFailure: Bool) async {}
    func scheduleImportedPlaylistSync() { scheduledPlaylistSyncs += 1 }

    // FOREGROUND_APP_METHODS
}

@main
private enum ForegroundConnectionTests {
    @MainActor
    static func main() async throws {
        let connectingApp = ForegroundAppHarness(phase: .connecting, secondsInBackground: 60)
        await connectingApp.applicationDidBecomeActive()
        let recoveryCount = await connectingApp.telegram.count()
        precondition(recoveryCount == 1)
        let shortBackground = ForegroundAppHarness(phase: .ready, secondsInBackground: 5)
        await shortBackground.applicationDidBecomeActive()
        let shortCount = await shortBackground.telegram.count()
        precondition(shortCount == 0)
        precondition(shortBackground.scheduledPlaylistSyncs == 1)
        precondition(connectingApp.scheduledPlaylistSyncs == 0,
                     "Playlist sync must wait until the account's library is ready")
        let signingIn = ForegroundAppHarness(phase: .connecting, secondsInBackground: 60)
        signingIn.isAddingAccount = true
        await signingIn.applicationDidBecomeActive()
        let loginCount = await signingIn.telegram.count()
        precondition(loginCount == 0)
        print("PASS: foreground recovery also runs while the library is connecting, skips short absences and login")

        for state in ["connectionStateReady", "connectionStateUpdating", "connectionStateWaitingForNetwork"] {
            let healthy = ForegroundConnectionHarness(state: state)
            try await healthy.recoverConnectionAfterStandby()
            let snapshot = await healthy.snapshot()
            precondition(snapshot.closed == 0)
        }
        let login = ForegroundConnectionHarness()
        await login.clearAuthorization()
        try await login.recoverConnectionAfterStandby()
        let loginSnapshot = await login.snapshot()
        precondition(loginSnapshot.closed == 0)
        print("PASS: healthy, updating, offline and unauthenticated clients are not restarted")

        let recovering = ForegroundConnectionHarness()
        await recovering.acknowledgeClose()
        async let first: Void = recovering.recoverConnectionAfterStandby()
        async let duplicate: Void = recovering.recoverConnectionAfterStandby()
        _ = try await (first, duplicate)
        let restored = await recovering.snapshot()
        precondition(restored.closed == 1 && restored.opened == 1 && restored.media == 42)
        await recovering.deliverUpdate(from: 1)
        await recovering.deliverUpdate(from: 2)
        let updates = await recovering.snapshot()
        precondition(updates.updates == 1)
        print("PASS: one restart for duplicate triggers, same media handles retained, stale updates ignored")

        let naturallyRecovered = ForegroundConnectionHarness()
        let naturalTask = Task { try await naturallyRecovered.recoverConnectionAfterStandby() }
        try await Task.sleep(for: .milliseconds(50))
        await naturallyRecovered.setState("connectionStateReady")
        try await naturalTask.value
        let naturalSnapshot = await naturallyRecovered.snapshot()
        precondition(naturalSnapshot.closed == 0)
        print("PASS: automatic TDLib recovery during the grace period prevents a restart")

        let switched = ForegroundConnectionHarness()
        let switchTask = Task { try await switched.recoverConnectionAfterStandby() }
        try await Task.sleep(for: .milliseconds(50))
        await switched.changeAccount()
        try await switchTask.value
        let switchedSnapshot = await switched.snapshot()
        precondition(switchedSnapshot.closed == 0)
        print("PASS: changing accounts during the grace period cancels recovery of the old account")

        let cancelled = ForegroundConnectionHarness()
        let cancelledTask = Task { try await cancelled.recoverConnectionAfterStandby() }
        try await Task.sleep(for: .milliseconds(50))
        cancelledTask.cancel()
        do { try await cancelledTask.value; preconditionFailure("Cancellation must propagate") }
        catch is CancellationError {}
        let cancelledSnapshot = await cancelled.snapshot()
        precondition(cancelledSnapshot.closed == 0)
        print("PASS: returning to the background cancels a pending recovery")

        let slowClose = ForegroundConnectionHarness()
        do {
            try await slowClose.recoverConnectionAfterStandby()
            preconditionFailure("A close request result alone must not permit reopening")
        } catch is ForegroundConnectionHarness.ServiceError {}
        let blocked = await slowClose.snapshot()
        precondition(blocked.closed == 1 && blocked.opened == 0 && blocked.pendingClose == 1)
        await slowClose.deliverClosed()
        try await slowClose.openAfterLateClose()
        let late = await slowClose.snapshot()
        precondition(late.opened == 1 && late.pendingClose == nil)
        print("PASS: close timeout keeps initialization gated until the actual Closed update")
    }
}
