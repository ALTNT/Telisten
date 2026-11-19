import Foundation
@preconcurrency import TDLibKit

private actor TDLibFileDownloadGate {
    private struct Waiter {
        var priority: AudioTransferPriority
        var continuation: CheckedContinuation<Void, Never>
    }

    private var activeFileIDs: Set<Int> = []
    private var waiters: [Int: [Waiter]] = [:]

    func acquire(fileID: Int, priority: AudioTransferPriority) async {
        guard activeFileIDs.contains(fileID) else {
            activeFileIDs.insert(fileID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[fileID, default: []].append(Waiter(priority: priority, continuation: continuation))
        }
    }

    func release(fileID: Int) {
        if var queued = waiters[fileID], !queued.isEmpty {
            let nextIndex = queued.firstIndex { $0.priority == .playback } ?? queued.startIndex
            let next = queued.remove(at: nextIndex)
            waiters[fileID] = queued.isEmpty ? nil : queued
            next.continuation.resume()
        } else {
            activeFileIDs.remove(fileID)
        }
    }
}

actor TelegramService {
    struct QRLoginCode: Sendable {
        var url: URL
        var expiresAt: Foundation.Date
    }

    enum QRLoginResult: Sendable {
        case code(QRLoginCode)
        case password(hint: String)
        case ready(TelegramAccount)
    }

    enum RequestCodeResult: Sendable {
        case code(hint: String, isEmail: Bool)
        case emailSetup
        case password(hint: String)
        case ready(TelegramAccount)
    }

    enum SignInResult: Sendable {
        case ready(TelegramAccount)
        case password(hint: String)
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case invalidAPIID
        case invalidCodeResponse
        case paidAuthorizationRequired(String)
        case signUpRequired
        case noConnection
        case downloadRedirect
        case incompleteDownload
        case expiredFileReference
        case playlistCreationFailed
        case playlistFolderFailed
        case playlistDeletionUnavailable
        case playlistTrackDeletionUnavailable
        case playlistRenameUnavailable
        case commentingUnavailable
        case groupCallUnavailable
        case groupCallCreationFailed
        case groupCallRequiresAdmin
        case inviteLinkUnavailable
        case contactInviteUnavailable
        case invalidPhoneNumber
        case invalidEmailAddress
        case emptyLoginCode
        case invalidSearchBot(String)
        case emptyBotMessage
        case unsupportedBotButton
        case sessionPersistenceFailed
        case sessionReplacementFailed
        case telegram(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add the Telegram API credentials to .env and rebuild the app."
            case .invalidAPIID: "The Telegram API credentials in .env are invalid."
            case .invalidCodeResponse: "Telegram returned an unexpected login response."
            case let .paidAuthorizationRequired(email): "Telegram requires paid authorization for this number. Contact \(email)."
            case .signUpRequired: "Create this account in the official Telegram app before signing in here."
            case .noConnection: "The Telegram connection is not ready."
            case .downloadRedirect: "Telegram could not provide this file through TDLib."
            case .incompleteDownload: "The file download ended before all bytes arrived."
            case .expiredFileReference: "This track reference expired. Refresh the music list and try again."
            case .playlistCreationFailed: "Telegram created no usable playlist chat."
            case .playlistFolderFailed: "Telegram did not accept the playlist folder update."
            case .playlistDeletionUnavailable: "Only Telegram channel playlists can be deleted."
            case .playlistTrackDeletionUnavailable: "This playlist entry cannot be deleted."
            case .playlistRenameUnavailable: "This playlist cannot be renamed."
            case .commentingUnavailable: "This Telegram post does not have a discussion where comments can be added."
            case .groupCallUnavailable: "There is no active Listen Together session in this music source."
            case .groupCallCreationFailed: "Telegram did not create a usable group audio call."
            case .groupCallRequiresAdmin: "Only an administrator can start Listen Together in this group or channel."
            case .inviteLinkUnavailable: "Telegram could not create an invite link for this group or channel."
            case .contactInviteUnavailable: "Telegram could not invite the selected contacts to this room."
            case .invalidPhoneNumber: "Enter a valid phone number in international format, including the country code."
            case .invalidEmailAddress: "Enter a valid email address."
            case .emptyLoginCode: "Enter the login code Telegram sent you."
            case let .invalidSearchBot(name): "\(name) is not an available Telegram bot. Check its username and try again."
            case .emptyBotMessage: "Enter something to send to the search bot."
            case .unsupportedBotButton: "This bot button needs a Telegram feature that Telisten does not support yet."
            case .sessionPersistenceFailed: "Telisten could not save the Telegram session in Keychain. Check the app signature and try again."
            case .sessionReplacementFailed: "Could not replace the local Telegram session. The existing session was preserved. Export logs for details."
            case let .telegram(message): message
            }
        }
    }

    private let keychain: KeychainStore
    private var credentials: TelegramCredentials?
    private var accountID: String
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private let fileDownloadGate = TDLibFileDownloadGate()
    private var videoSessions: [UUID: Int] = [:]
    private var videoDownloadWindows: [UUID: VideoBufferWindow] = [:]
    private var videoPlaybackChoices: [String: (date: Foundation.Date, choice: VideoPlaybackChoice)] = [:]
    private var refreshedFileIDs: [String: Int] = [:]
    private var authorizationState: AuthorizationState?
    private var connectionState = "unknown" {
        didSet {
            guard connectionState != oldValue else { return }
            for observer in connectionStateObservers.values { observer.yield(connectionState) }
        }
    }
    private var connectionStateObservers: [UUID: AsyncStream<String>.Continuation] = [:]
    private var loginTokenUpdateRevision: UInt64 = 0
    private var searchBotPeers: [String: MusicChat] = [:]
    private var isResolvingImportedMusic = false
    private var importedMusicIsForeground = true
    private var importedMusicWaitBudget: ImportedMusicWaitBudget?
    private var importedMusicRetryAfter: [String: Foundation.Date] = [:]
    private var lyricsAttachmentCache: [String: [TelegramLyricsAttachment]] = [:]
    private var replacingSession = false
    private var reconnectingClient = false
    private var closingClientID: Int32?
    private var desiredProxy: SOCKS5ProxyConfiguration?
    private var appliedProxy: SOCKS5ProxyConfiguration?
    private var proxyClientReady = false
    private var proxyClientID: Int32?
    private var proxyUpdateTask: Task<Void, Swift.Error>?

    func setConnectionProxy(_ proxy: SOCKS5ProxyConfiguration?) async throws {
        desiredProxy = proxy
        // Network polling must not reopen a database while a reauthorized
        // session is being moved into place.
        guard !replacingSession, !reconnectingClient, closingClientID == nil else { return }
        // Saving a proxy must also recover a client that was never initialized
        // or was closed after a failed startup, rather than only updating UI.
        if client == nil, credentials != nil {
            do {
                _ = try await requireClient()
            } catch {
                PlaybackDiagnostics.log("telegram_proxy_client_unavailable", error: error)
                throw error
            }
        }
        let previous = proxyUpdateTask
        // Actor methods can reenter while TDLib is awaited. Chain changes so an
        // older Wi-Fi update cannot finish after a newer mobile-data update.
        let task = Task {
            _ = try? await previous?.value
            guard let client = self.client, self.proxyClientReady, !self.replacingSession,
                  !self.reconnectingClient, self.closingClientID == nil else {
                PlaybackDiagnostics.log("telegram_proxy_deferred clientAvailable=\(self.client != nil) clientReady=\(self.proxyClientReady)")
                return
            }
            let target = self.desiredProxy
            guard self.proxyClientID != client.id || self.appliedProxy != target else { return }
            PlaybackDiagnostics.log("telegram_proxy_apply_start client=\(client.id) target=\(target.map { "SOCKS5 \($0.server):\($0.port)" } ?? "direct")")
            var enabledID: Int?
            if let target {
                guard target.isValid, let port = Int(target.port) else { throw ServiceError.telegram("Invalid SOCKS5 proxy settings.") }
                let added = try await client.addProxy(
                    comment: "Telisten", enable: true,
                    proxy: Proxy(port: port, server: target.server, type: .proxyTypeSocks5(
                        ProxyTypeSocks5(password: target.password, username: target.username)
                    ))
                )
                enabledID = added.id
            } else {
                _ = try await client.disableProxy()
            }
            // Check TDLib's actual enabled proxy before reporting success.
            let proxies = try await client.getProxies()
            let enabled = proxies.proxies.first(where: \.isEnabled)
            guard enabled?.id == enabledID else {
                throw ServiceError.telegram("TDLib did not apply the selected proxy.")
            }
            self.appliedProxy = target
            self.proxyClientID = client.id
            PlaybackDiagnostics.log("telegram_proxy_apply_complete client=\(client.id) enabled=\(enabled != nil) proxyID=\(enabledID ?? 0)")
            // Remove obsolete credentials from TDLib's persisted proxy list.
            for item in proxies.proxies where item.comment == "Telisten" && item.id != enabledID {
                _ = try? await client.removeProxy(proxyId: item.id)
            }
        }
        proxyUpdateTask = task
        do {
            try await task.value
        } catch {
            PlaybackDiagnostics.log("telegram_proxy_apply_failed", error: error)
            throw error
        }
    }

    func testConnectionProxy(_ proxy: SOCKS5ProxyConfiguration) async throws {
        guard proxy.isValid, let port = Int(proxy.normalized.port) else {
            throw ServiceError.telegram("Invalid SOCKS5 proxy settings.")
        }
        do {
            let client = try await requireClient()
            let selected = Proxy(port: port, server: proxy.normalized.server, type: .proxyTypeSocks5(
                ProxyTypeSocks5(password: proxy.password, username: proxy.username)
            ))
            // Let TDLib choose its latency probe target instead of forcing DC2.
            // Bound the callback: one slow probe must not hang the settings UI.
            let seconds = try await VideoListRequest<Double>.run(timeout: .seconds(30)) { completion in
                try client.pingProxy(proxy: selected) { result in
                    completion(result.map { $0.seconds })
                }
            }
            PlaybackDiagnostics.log("telegram_proxy_test_complete method=pingProxy seconds=\(seconds)")
        } catch {
            let readable = readableLoginError(error)
            PlaybackDiagnostics.log("telegram_proxy_test_failed method=pingProxy timeout=30", error: readable)
            if (error as? URLError)?.code == .timedOut {
                throw ServiceError.telegram("Telegram did not answer the latency probe within 30 seconds. Some account requests may still work.")
            }
            throw readable
        }
    }

    func connectionProxyIsApplied(_ proxy: SOCKS5ProxyConfiguration?) -> Bool {
        guard let client, proxyClientReady else { return false }
        return proxyClientID == client.id && appliedProxy == proxy
    }

    init(keychain: KeychainStore) {
        self.keychain = keychain
        accountID = UserDefaults.standard.string(forKey: "telegram.activeAccountID") ?? "legacy"
    }

    func configure(_ value: TelegramCredentials) throws {
        let hash = value.apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.apiID > 0, hash.count == 32,
              hash.allSatisfy({ $0.isHexDigit }) else {
            throw ServiceError.invalidAPIID
        }
        credentials = TelegramCredentials(apiID: value.apiID, apiHash: hash)
    }

    func hasAuthorizedSession() -> Bool {
        guard credentials != nil else { return false }
        if case .authorizationStateReady? = authorizationState { return true }
        return UserDefaults.standard.bool(forKey: authorizationDefaultsKey)
    }

    func useAccount(_ id: String, clearExisting: Bool = false) async {
        await closeClient()
        accountID = id
        refreshedFileIDs.removeAll()
        authorizationState = nil
        searchBotPeers.removeAll()
        lyricsAttachmentCache.removeAll()
        if clearExisting {
            removeTDLibStorage(for: id)
            _ = keychain.setTDLibAccount(id, authorized: false)
        }
    }

    func restoreSession() async throws -> [MusicChat] {
        let client = try await requireClient()
        let state = try await client.getAuthorizationState()
        authorizationState = state
        guard case .authorizationStateReady = state else {
            _ = keychain.setTDLibAccount(accountID, authorized: false)
            return []
        }
        _ = keychain.setTDLibAccount(accountID, authorized: true)
        return try await loadChats()
    }

    func currentAccount() async throws -> TelegramAccount {
        let client = try await requireReadyClient()
        return TelegramMapping.account(from: try await client.getMe(), accountID: accountID)
    }

    func sendCode(to phone: String) async throws -> RequestCodeResult {
        let digits = phone.filter(\.isNumber)
        guard (8...15).contains(digits.count) else { throw ServiceError.invalidPhoneNumber }
        let client = try await requireClient()
        do {
            _ = try await client.setAuthenticationPhoneNumber(phoneNumber: "+" + digits, settings: nil)
            return try await authenticationResultAfterCodeRequest()
        } catch {
            throw readableLoginError(error)
        }
    }

    func signIn(code: String) async throws -> SignInResult {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCode.isEmpty else { throw ServiceError.emptyLoginCode }
        let client = try await requireClient()
        do {
            _ = try await client.checkAuthenticationCode(code: cleanCode)
            switch try await waitForAuthorizationState({ state in
                switch state {
                case .authorizationStateReady, .authorizationStateWaitPassword, .authorizationStateWaitRegistration:
                    true
                default:
                    false
                }
            }) {
            case .authorizationStateReady:
                return .ready(try await acceptAuthorization())
            case let .authorizationStateWaitPassword(value):
                return .password(hint: value.passwordHint)
            case .authorizationStateWaitRegistration:
                throw ServiceError.signUpRequired
            default:
                throw ServiceError.invalidCodeResponse
            }
        } catch {
            throw readableLoginError(error)
        }
    }

    func sendLoginEmailCode(to email: String) async throws -> String {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@"), cleanEmail.contains(".") else {
            throw ServiceError.invalidEmailAddress
        }
        let client = try await requireClient()
        do {
            _ = try await client.setAuthenticationEmailAddress(emailAddress: cleanEmail)
            let state = try await waitForAuthorizationState { state in
                if case .authorizationStateWaitEmailCode = state { return true }
                return false
            }
            guard case let .authorizationStateWaitEmailCode(value) = state else {
                throw ServiceError.invalidCodeResponse
            }
            return value.codeInfo.emailAddressPattern
        } catch {
            throw readableLoginError(error)
        }
    }

    func verifyLoginEmail(code: String) async throws -> RequestCodeResult {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCode.isEmpty else { throw ServiceError.emptyLoginCode }
        let client = try await requireClient()
        do {
            let emailCode = EmailAddressAuthentication.emailAddressAuthenticationCode(
                EmailAddressAuthenticationCode(code: cleanCode)
            )
            _ = try await client.checkAuthenticationEmailCode(code: emailCode)
            return try await authenticationResultAfterCodeRequest()
        } catch {
            throw readableLoginError(error)
        }
    }

    func checkPassword(_ password: String) async throws -> TelegramAccount {
        let client = try await requireClient()
        do {
            _ = try await client.checkAuthenticationPassword(password: password)
            _ = try await waitForAuthorizationState { state in
                if case .authorizationStateReady = state { return true }
                return false
            }
            return try await acceptAuthorization()
        } catch {
            throw readableLoginError(error)
        }
    }

    func currentLoginTokenUpdateRevision() -> UInt64 {
        loginTokenUpdateRevision
    }

    func discardPendingQRCodeLoginSession() async {
        guard !hasAuthorizedSession() else { return }
        await closeClient()
        removeTDLibStorage(for: accountID)
        _ = keychain.setTDLibAccount(accountID, authorized: false)
        authorizationState = nil
    }

    func restartPendingQRCodeLoginTransport() async {
        guard !hasAuthorizedSession() else { return }
        await closeClient()
        authorizationState = nil
    }

    func exportQRCodeLogin(exceptUserIDs: [Int64]) async throws -> QRLoginResult {
        let client = try await requireClient()
        do {
            let currentState = try await client.getAuthorizationState()
            authorizationState = currentState
            let state: AuthorizationState
            switch currentState {
            case .authorizationStateWaitOtherDeviceConfirmation,
                 .authorizationStateWaitPassword,
                 .authorizationStateWaitRegistration,
                 .authorizationStateReady:
                state = currentState
            default:
                _ = try await client.requestQrCodeAuthentication(
                    otherUserIds: Array(Set(exceptUserIDs.filter { $0 > 0 })).sorted()
                )
                state = try await waitForAuthorizationState { state in
                    switch state {
                    case .authorizationStateWaitOtherDeviceConfirmation,
                         .authorizationStateWaitPassword,
                         .authorizationStateWaitRegistration,
                         .authorizationStateReady:
                        true
                    default:
                        false
                    }
                }
            }
            switch state {
            case let .authorizationStateWaitOtherDeviceConfirmation(value):
                guard let url = URL(string: value.link) else { throw ServiceError.invalidCodeResponse }
                return .code(QRLoginCode(url: url, expiresAt: Foundation.Date().addingTimeInterval(30)))
            case let .authorizationStateWaitPassword(value):
                return .password(hint: value.passwordHint)
            case .authorizationStateWaitRegistration:
                throw ServiceError.signUpRequired
            case .authorizationStateReady:
                return .ready(try await acceptAuthorization())
            default:
                throw ServiceError.invalidCodeResponse
            }
        } catch {
            throw readableLoginError(error)
        }
    }

    func replaceCurrentSession(withAccountID replacementAccountID: String) async throws {
        guard replacementAccountID != accountID else { return }
        guard !replacingSession else { throw ServiceError.sessionReplacementFailed }
        replacingSession = true
        defer { replacingSession = false }

        let sourceID = accountID
        let sourceURL = storageURL(for: sourceID)
        let destinationURL = storageURL(for: replacementAccountID)
        await closeClient()
        var backupURL: URL?
        var movedNewSession = false
        var replacementStage = "checkSource"
        PlaybackDiagnostics.log("telegram_session_replacement_start")
        do {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ServiceError.sessionReplacementFailed
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                // finishLogin calls this only after authorizing the same
                // Telegram user. Back up even when no failure was observed
                // in this process, including after an app restart.
                replacementStage = "backupExistingDatabase"
                let backup = destinationURL.deletingLastPathComponent().appendingPathComponent(
                    destinationURL.lastPathComponent + "-backup-" + UUID().uuidString,
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: destinationURL, to: backup)
                backupURL = backup
                PlaybackDiagnostics.log("telegram_session_database_backed_up")
            }
            replacementStage = "moveAuthorizedDatabase"
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            movedNewSession = true
            replacementStage = "copyDatabaseKey"
            guard keychain.copyTDLibDatabaseKey(from: sourceID, to: replacementAccountID) else {
                throw ServiceError.sessionPersistenceFailed
            }
        } catch {
            PlaybackDiagnostics.log("telegram_session_replacement_failed stage=\(replacementStage)", error: error)
            // Roll back filesystem changes if the new session/key cannot commit.
            if movedNewSession {
                do { try FileManager.default.moveItem(at: destinationURL, to: sourceURL) }
                catch { PlaybackDiagnostics.log("telegram_session_replacement_rollback_failed stage=restoreNewSession", error: error) }
            }
            if let backupURL {
                do { try FileManager.default.moveItem(at: backupURL, to: destinationURL) }
                catch { PlaybackDiagnostics.log("telegram_session_replacement_rollback_failed stage=restoreBackup", error: error) }
            }
            if replacementStage == "copyDatabaseKey" { throw ServiceError.sessionPersistenceFailed }
            throw ServiceError.sessionReplacementFailed
        }
        PlaybackDiagnostics.log("telegram_session_replacement_complete")
        accountID = replacementAccountID
        authorizationState = nil
        _ = keychain.setTDLibAccount(sourceID, authorized: false)
        _ = keychain.setTDLibAccount(replacementAccountID, authorized: true)
        UserDefaults.standard.set(true, forKey: authorizationDefaultsKey)
    }

    func loadChats() async throws -> [MusicChat] {
        let client = try await requireReadyClient()
        _ = try await client.loadChats(chatList: nil, limit: 100)
        let result = try await client.getChats(chatList: nil, limit: 1_000)
        var chats: [MusicChat] = []
        for chatID in result.chatIds {
            try Task.checkCancellation()
            guard let chat = try? await client.getChat(chatId: chatID),
                  let mapped = TelegramMapping.chat(from: chat) else { continue }
            chats.append(mapped)
        }
        return chats
    }

    func searchMusic(
        in chat: MusicChat,
        query: String,
        offsetID: Int64 = 0,
        limit: Int32 = 30
    ) async throws -> [Track] {
        guard limit > 0, let chatID = TelegramMapping.chatID(from: chat.id) else { return [] }
        let client = try await requireReadyClient()
        let filters: [SearchMessagesFilter] = [.searchMessagesFilterAudio, .searchMessagesFilterDocument]
        var tracks: [Track] = []
        var seen: Set<String> = []
        for filter in filters {
            let result = try await client.searchChatMessages(
                chatId: chatID,
                filter: filter,
                fromMessageId: offsetID,
                limit: Int(limit),
                offset: 0,
                query: query,
                senderId: nil,
                topicId: nil
            )
            for message in result.messages {
                guard let track = TelegramMapping.track(from: message),
                      seen.insert(track.deduplicationID).inserted else { continue }
                tracks.append(track)
            }
        }
        return Array(tracks.sorted { $0.messageID > $1.messageID }.prefix(Int(limit)))
    }

    func searchAllMusic(query: String) async throws -> [Track] {
        let client = try await requireReadyClient()
        var tracks: [Track] = []
        var seen: Set<String> = []
        for filter in [SearchMessagesFilter.searchMessagesFilterAudio, .searchMessagesFilterDocument] {
            let result = try await client.searchMessages(
                chatList: nil,
                chatTypeFilter: nil,
                filter: filter,
                limit: 100,
                maxDate: 0,
                minDate: 0,
                offset: nil,
                query: query
            )
            for message in result.messages {
                guard let track = TelegramMapping.track(from: message),
                      seen.insert(track.deduplicationID).inserted else { continue }
                tracks.append(track)
            }
        }
        return tracks.sorted { $0.date > $1.date }
    }

    func attachedLyrics(for track: Track, in sourceChat: MusicChat?) async throws -> [AttachedLRC] {
        guard let chatID = TelegramMapping.chatID(from: sourceChat?.id ?? track.chatID) else { return [] }
        let client = try await requireReadyClient()
        var attachments = lyricsAttachmentCache[track.chatID] ?? []
        let queries = [track.displayTitle, track.artist, track.fileName.deletingPathExtension]
            .map { $0.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seenQueries: Set<String> = []
        for query in queries where seenQueries.insert(query.lowercased()).inserted {
            let result = try await client.searchChatMessages(
                chatId: chatID,
                filter: .searchMessagesFilterDocument,
                fromMessageId: 0,
                limit: 50,
                offset: 0,
                query: query,
                senderId: nil,
                topicId: nil
            )
            attachments.append(contentsOf: result.messages.compactMap(TelegramMapping.lyricsAttachment(from:)))
        }
        attachments = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
            .values
            .sorted { $0.date > $1.date }
        lyricsAttachmentCache[track.chatID] = attachments

        let matches = attachments
            .compactMap { attachment -> (TelegramLyricsAttachment, Int)? in
                let score = lyricsAttachmentMatchScore(attachment.fileName, track: track)
                return score > 0 ? (attachment, score) : nil
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.date > $1.0.date
            }
            .prefix(4)

        var values: [AttachedLRC] = []
        for (attachment, _) in matches where attachment.size > 0 && attachment.size <= 2 * 1_024 * 1_024 {
            guard let fileID = TelegramMapping.fileID(from: attachment.documentID) else { continue }
            let data = try await downloadFile(fileID: fileID, offset: 0, limit: 0)
            guard let contents = decodeLyricsText(data), !contents.isEmpty else { continue }
            values.append(AttachedLRC(id: attachment.id, fileName: attachment.fileName, contents: contents))
        }
        return values
    }

    func sendBotSearchCommand(config: SearchBotConfig, query: String) async throws -> [BotSearchMessage] {
        try await sendBotMessage(config.command(for: query), to: config)
    }

    func sendBotMessage(_ text: String, to config: SearchBotConfig) async throws -> [BotSearchMessage] {
        try await sendBotMessage(text, to: config, settleForAudio: false)
    }

    private func sendBotMessage(
        _ text: String,
        to config: SearchBotConfig,
        settleForAudio: Bool
    ) async throws -> [BotSearchMessage] {
        guard !isResolvingImportedMusic else {
            throw ServiceError.telegram("A playlist song is being requested. Wait for it to finish before using the bot.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.emptyBotMessage
        }
        let bot = try await resolveSearchBot(config)
        let client = try await requireReadyClient()
        let baseline = try await botHistoryMessages(client: client, chatID: bot.peerID, limit: 60)
        let input = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: false,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        do {
            _ = try await client.sendMessage(
                chatId: bot.peerID,
                inputMessageContent: input,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )
        } catch {
            throw ServiceError.telegram("Could not send a message to \(config.displayBotName): \(error.localizedDescription)")
        }
        let deadline = Foundation.Date().addingTimeInterval(settleForAudio ? 30 : 20)
        let baselineIDs = Set(baseline.map(\.id))
        var baselineMessages: [Int64: BotSearchMessage] = [:]
        for message in baseline where !message.isOutgoing {
            guard let mapped = TelegramMapping.botMessage(from: message) else { continue }
            baselineMessages[mapped.id] = mapped
        }
        var latestIncoming: [BotSearchMessage] = []
        var sentCommand: BotSearchMessage?
        while Foundation.Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 400_000_000)
            let history = try await botHistoryMessages(client: client, chatID: bot.peerID, limit: 60)
            let incoming = history.compactMap(TelegramMapping.botMessage(from:)).filter { !$0.isOutgoing }
            latestIncoming = incoming.filter { baselineMessages[$0.id] != $0 }
            let confirmedCommand = history.last(where: {
                $0.isOutgoing
                    && $0.sendingState == nil
                    && !baselineIDs.contains($0.id)
                    && TelegramMapping.text(from: $0).trimmingCharacters(in: .whitespacesAndNewlines)
                        == text.trimmingCharacters(in: .whitespacesAndNewlines)
            }).flatMap(TelegramMapping.botMessage(from:))
            if let confirmedCommand { sentCommand = confirmedCommand }
            if latestIncoming.contains(where: { $0.track != nil }) || (!latestIncoming.isEmpty && !settleForAudio) {
                break
            }
        }
        var result = latestIncoming
        if let sentCommand { result.append(sentCommand) }
        return result.sorted { $0.id < $1.id }
    }

    func pressBotButton(_ button: BotSearchButton, for config: SearchBotConfig) async throws -> [BotSearchMessage] {
        guard !isResolvingImportedMusic else {
            throw ServiceError.telegram("A playlist song is being requested. Wait for it to finish before using the bot.")
        }
        switch button.action {
        case let .sendText(text):
            return try await sendBotMessage(text, to: config, settleForAudio: true)
        case let .callback(messageID, data):
            let bot = try await resolveSearchBot(config)
            let baseline: [BotSearchMessage]
            do {
                baseline = try await botSearchHistory(config: config, limit: 60)
            } catch {
                throw readableBotButtonError(error, botName: config.displayBotName)
            }
            let client = try await requireReadyClient()
            let payload = CallbackQueryPayload.callbackQueryPayloadData(CallbackQueryPayloadData(data: data))
            do {
                _ = try await client.getCallbackQueryAnswer(
                    chatId: bot.peerID,
                    messageId: messageID,
                    payload: payload
                )
            } catch let error as TDLibKit.Error {
                let detail = error.message.uppercased()
                guard error.code == 502 || detail.contains("BOT_RESPONSE_TIMEOUT") else {
                    throw readableBotButtonError(error, botName: config.displayBotName)
                }
            } catch {
                throw readableBotButtonError(error, botName: config.displayBotName)
            }
            do {
                return try await waitForBotResponse(
                    config: config,
                    comparedWith: baseline,
                    limit: 60,
                    settleForAudio: true
                )
            } catch {
                throw readableBotButtonError(error, botName: config.displayBotName)
            }
        case .openURL:
            return try await botSearchHistory(config: config)
        case .unsupported:
            throw ServiceError.unsupportedBotButton
        }
    }

    func botSearchHistory(config: SearchBotConfig, limit: Int32 = 60) async throws -> [BotSearchMessage] {
        let bot = try await resolveSearchBot(config)
        let client = try await requireReadyClient()
        let messages = try await botHistoryMessages(client: client, chatID: bot.peerID, limit: Int(limit))
        return messages
            .filter { $0.sendingState == nil }
            .sorted { $0.id < $1.id }
            .compactMap(TelegramMapping.botMessage(from:))
    }

    func setImportedMusicForeground(_ foreground: Bool) {
        importedMusicIsForeground = foreground
        importedMusicWaitBudget?.setForeground(foreground, now: Foundation.Date())
        PlaybackDiagnostics.log("imported_music_foreground active=\(foreground) resolving=\(isResolvingImportedMusic)")
    }

    func resolveImportedMusic(_ entry: ImportedPlaylistEntry, using config: SearchBotConfig) async throws -> Track {
        guard !isResolvingImportedMusic else {
            throw ServiceError.telegram("Another playlist song is still being requested. Please try again shortly.")
        }
        let botKey = "\(accountID):\(config.normalizedBotName.lowercased())"
        if let retryAfter = importedMusicRetryAfter[botKey], retryAfter > Foundation.Date() {
            throw ServiceError.telegram("The previous music request may still be queued. Wait one minute before retrying.")
        }
        isResolvingImportedMusic = true
        let requestID = UUID().uuidString
        var completed = false
        var startedRequest = false
        defer {
            isResolvingImportedMusic = false
            importedMusicWaitBudget = nil
            if startedRequest && !completed { importedMusicRetryAfter[botKey] = Foundation.Date().addingTimeInterval(60) }
        }
        let bot = try await resolveSearchBot(config)
        let client = try await requireReadyClient()
        let baseline = try await botHistoryMessages(client: client, chatID: bot.peerID, limit: 100)
        let baselineIDs = Set(baseline.map(\.id))
        let command = "/music \(entry.songURL.absoluteString)"
        try Task.checkCancellation()
        startedRequest = true
        _ = try await client.sendMessage(chatId: bot.peerID,
            inputMessageContent: .inputMessageText(InputMessageText(clearDraft: false, linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: command))),
            options: nil, replyMarkup: nil, replyTo: nil, topicId: nil)
        importedMusicWaitBudget = ImportedMusicWaitBudget(now: Foundation.Date(), isForeground: importedMusicIsForeground)
        PlaybackDiagnostics.log("imported_music_start request=\(requestID) expectedDuration=\(entry.duration) foreground=\(importedMusicIsForeground)")
        var commandIDs: Set<Int64> = []
        var matcher = ImportedMusicReplyMatcher(entry: entry)
        var lastReply = ""
        var loggedCandidates: Set<String> = []
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            let history = try await botHistoryMessages(client: client, chatID: bot.peerID, limit: 100)
            for message in history where message.isOutgoing && message.sendingState == nil && !baselineIDs.contains(message.id) {
                if TelegramMapping.text(from: message).trimmingCharacters(in: .whitespacesAndNewlines) == command {
                    commandIDs.insert(message.id)
                }
            }
            // Progress messages may be edited, and the final audio may reply to
            // that progress message rather than directly to the /music command.
            var unavailableMessage: String?
            for message in history.sorted(by: { $0.id < $1.id }) where !message.isOutgoing && !baselineIDs.contains(message.id) {
                var replyID: Int64?
                if case let .messageReplyToMessage(reply) = message.replyTo,
                   reply.chatId == 0 || reply.chatId == bot.peerID { replyID = reply.messageId }
                let belongsToRequest = matcher.isRelated(messageID: message.id, replyID: replyID, commandIDs: commandIDs)
                if belongsToRequest {
                    let text = TelegramMapping.text(from: message)
                    if !text.isEmpty { lastReply = String(text.prefix(300)) }
                    if let reason = matcher.unavailableMessage(in: text, isRelated: belongsToRequest) {
                        unavailableMessage = String(reason.prefix(300))
                    }
                }
                guard let track = TelegramMapping.track(from: message) else {
                    if case let .messageDocument(content) = message.content,
                       loggedCandidates.insert("document:\(message.id)").inserted {
                        PlaybackDiagnostics.log("imported_music_unmapped_document request=\(requestID) mime=\(content.document.mimeType)")
                    }
                    continue
                }
                let accepted = matcher.accepts(track, isRelated: belongsToRequest, replyID: replyID)
                if loggedCandidates.insert("\(message.id):\(track.hashValue):\(belongsToRequest)").inserted {
                    let reason = accepted ? "matched" : (replyID != nil && !belongsToRequest ? "unrelated_reply"
                        : (belongsToRequest ? "duration_mismatch" : "metadata_mismatch"))
                    PlaybackDiagnostics.log("imported_music_candidate request=\(requestID) related=\(belongsToRequest) hasReply=\(replyID != nil) expectedDuration=\(entry.duration) actualDuration=\(track.duration) reason=\(reason)")
                }
                if accepted {
                    completed = true
                    return track
                }
            }
            if let unavailableMessage {
                // A definitive negative reply completes the bot's job. It must
                // release the gate without imposing the timeout retry delay.
                completed = true
                PlaybackDiagnostics.log("imported_music_unavailable request=\(requestID)")
                throw ImportedMusicError.unavailable(unavailableMessage)
            }
            // Always inspect fresh history before deciding to time out. A file
            // may have arrived while this task was suspended in the background.
            if importedMusicWaitBudget?.hasExpired(now: Foundation.Date()) == true { break }
        }
        PlaybackDiagnostics.log("imported_music_timeout request=\(requestID) hasCommand=\(!commandIDs.isEmpty) hasProgress=\(!lastReply.isEmpty) foreground=\(importedMusicIsForeground)")
        let timeoutMessage = localizedUI("Timed out waiting for the music bot's audio file. You can retry or choose received audio.")
        throw ServiceError.telegram(lastReply.isEmpty ? timeoutMessage : "\(timeoutMessage)\n\(lastReply)")
    }

    func searchBotChat(_ config: SearchBotConfig) async throws -> MusicChat {
        try await resolveSearchBot(config)
    }

    func prepareImportedPlaylistSync(expectedAccountID: String, expectedOwnerID: Int64?, createIfMissing: Bool) async throws -> ImportedPlaylistSyncLocation {
        let client = try await requireReadyClient()
        try checkImportedSyncAccount(expectedAccountID, client: client)
        let me = try await client.getMe()
        guard expectedOwnerID == nil || expectedOwnerID == me.id else { throw ImportedPlaylistSyncError.accountChanged }
        let saved = try await client.createPrivateChat(force: true, userId: me.id)
        let marker = "#TelistenImportedPlaylistSyncIndexV1"
        var channelIDs: Set<Int64> = []
        var from: Int64 = 0
        repeat {
            try checkImportedSyncAccount(expectedAccountID, client: client)
            let page = try await client.searchChatMessages(chatId: saved.id, filter: nil, fromMessageId: from,
                limit: 100, offset: 0, query: marker, senderId: nil, topicId: nil)
            for message in page.messages where message.sendingState == nil {
                let lines = TelegramMapping.text(from: message).components(separatedBy: .newlines)
                if lines.count == 3, lines[0] == marker, lines[1] == String(me.id), let id = Int64(lines[2]) {
                    channelIDs.insert(id)
                }
            }
            let next = page.nextFromMessageId
            guard next == 0 || next != from else { throw ImportedPlaylistSyncError.invalidData }
            from = next
        } while from != 0
        if channelIDs.isEmpty {
            // Recover a channel created before a crash that prevented its index
            // message from being sent. The title alone never authorizes uploads.
            let candidates = try await client.searchChatsOnServer(limit: 100, query: "Telisten Sync", typeFilter: nil)
            for id in candidates.chatIds {
                if (try? await validateImportedSyncChannel(id, ownerID: me.id, client: client)) == true { channelIDs.insert(id) }
            }
            if channelIDs.isEmpty && !createIfMissing {
                return ImportedPlaylistSyncLocation(ownerUserID: me.id, chatIDs: [], uploadChatID: 0)
            }
            if channelIDs.isEmpty {
                try checkImportedSyncAccount(expectedAccountID, client: client)
                let chat = try await client.createNewSupergroupChat(
                    description: importedSyncChannelDescription(me.id), forImport: false, isChannel: true,
                    isForum: false, location: nil, messageAutoDeleteTime: 0, title: "Telisten Sync")
                channelIDs.insert(chat.id)
            }
            for id in channelIDs.sorted() {
                let text = "\(marker)\n\(me.id)\n\(id)"
                _ = try await sendImportedSyncMessage(.inputMessageText(InputMessageText(clearDraft: false,
                    linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))),
                    caption: text, chatID: saved.id, expectedAccountID: expectedAccountID, client: client)
            }
        }
        // Simultaneous first-time setup may create two channels. Read both
        // indexed streams and consistently publish to the same canonical one.
        for id in channelIDs {
            try checkImportedSyncAccount(expectedAccountID, client: client)
            guard try await validateImportedSyncChannel(id, ownerID: me.id, client: client) else {
                throw ImportedPlaylistSyncError.unsafeChannel
            }
        }
        return ImportedPlaylistSyncLocation(ownerUserID: me.id, chatIDs: channelIDs.sorted(), uploadChatID: channelIDs.sorted()[0])
    }

    func pullImportedPlaylistSync(chatID: Int64, after messageID: Int64, ownerID: Int64,
                                  expectedAccountID: String) async throws -> ImportedPlaylistSyncPull {
        let client = try await requireReadyClient()
        try checkImportedSyncAccount(expectedAccountID, client: client)
        guard try await validateImportedSyncChannel(chatID, ownerID: ownerID, client: client) else {
            throw ImportedPlaylistSyncError.unsafeChannel
        }
        var from: Int64 = 0
        var seen: Set<Int64> = []
        var newest = messageID
        var records: [ImportedPlaylistSyncRecord] = []
        while true {
            try checkImportedSyncAccount(expectedAccountID, client: client)
            let page = try await client.getChatHistory(chatId: chatID, fromMessageId: from, limit: 100, offset: 0, onlyLocal: false)
            let messages = (page.messages ?? []).filter { $0.id > messageID && seen.insert($0.id).inserted }
            if messages.isEmpty { break }
            for message in messages where message.sendingState == nil {
                newest = max(newest, message.id)
                guard case let .messageDocument(content) = message.content,
                      content.caption.text.hasPrefix(ImportedPlaylistSyncEnvelope.marker + " "),
                      content.document.fileName.hasPrefix("telisten-playlist-sync-") else { continue }
                let file = content.document.document
                guard max(file.size, file.expectedSize) <= Int64(ImportedPlaylistSyncEnvelope.maximumBytes) else {
                    throw ImportedPlaylistSyncError.tooLarge
                }
                let local = try await client.downloadFile(fileId: file.id,
                    limit: Int64(ImportedPlaylistSyncEnvelope.maximumBytes + 1), offset: 0, priority: 16, synchronous: true)
                try checkImportedSyncAccount(expectedAccountID, client: client)
                guard !local.local.path.isEmpty else { throw ServiceError.incompleteDownload }
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: local.local.path))
                let data: Data
                do {
                    defer { try? handle.close() }
                    data = try handle.read(upToCount: ImportedPlaylistSyncEnvelope.maximumBytes + 1) ?? Data()
                }
                guard local.local.isDownloadingCompleted else { throw ServiceError.incompleteDownload }
                let envelope = try ImportedPlaylistSyncEnvelope.decode(data, ownerUserID: ownerID)
                guard content.caption.text == "\(ImportedPlaylistSyncEnvelope.marker) \(envelope.id)" else {
                    throw ImportedPlaylistSyncError.invalidData
                }
                records.append(contentsOf: envelope.records)
            }
            guard let oldest = messages.map(\.id).min(), oldest > messageID else { break }
            from = oldest
        }
        return ImportedPlaylistSyncPull(records: records, lastMessageID: newest)
    }

    func pushImportedPlaylistSync(_ envelope: ImportedPlaylistSyncEnvelope, chatID: Int64,
                                  expectedAccountID: String) async throws {
        let client = try await requireReadyClient()
        try checkImportedSyncAccount(expectedAccountID, client: client)
        guard try await validateImportedSyncChannel(chatID, ownerID: envelope.ownerUserID, client: client) else {
            throw ImportedPlaylistSyncError.unsafeChannel
        }
        let data = try envelope.encoded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telisten-playlist-sync-\(envelope.id).json")
        try data.write(to: url, options: .atomic)
        var confirmed = false
        defer { if confirmed { try? FileManager.default.removeItem(at: url) } }
        let caption = "\(ImportedPlaylistSyncEnvelope.marker) \(envelope.id)"
        _ = try await sendImportedSyncMessage(.inputMessageDocument(InputMessageDocument(
            caption: FormattedText(entities: [], text: caption), document: InputDocument(disableContentTypeDetection: true,
                document: .inputFileLocal(InputFileLocal(path: url.path)), thumbnail: nil))),
            caption: caption, chatID: chatID, expectedAccountID: expectedAccountID, client: client)
        confirmed = true
    }

    func restoreImportedAudioSource(_ source: ImportedAudioSource, expectedAccountID: String) async throws -> Track? {
        let client = try await requireReadyClient()
        try checkImportedSyncAccount(expectedAccountID, client: client)
        guard let chatID = Int64(source.chatID) else { return nil }
        let message: Message
        do { message = try await client.getMessage(chatId: chatID, messageId: source.messageID) }
        catch let error as TDLibKit.Error where error.code == 400 || error.code == 404 { return nil }
        try checkImportedSyncAccount(expectedAccountID, client: client)
        guard let track = TelegramMapping.track(from: message),
              source.remoteUniqueID == nil || source.remoteUniqueID == track.remoteUniqueID else { return nil }
        return track
    }

    private func importedSyncChannelDescription(_ ownerID: Int64) -> String {
        "Telisten imported playlist sync v1\nowner:\(ownerID)"
    }

    private func validateImportedSyncChannel(_ chatID: Int64, ownerID: Int64, client: TDLibClient) async throws -> Bool {
        let chat = try await client.getChat(chatId: chatID)
        guard case let .chatTypeSupergroup(type) = chat.type, type.isChannel else { return false }
        let group = try await client.getSupergroup(supergroupId: type.supergroupId)
        guard case let .chatMemberStatusCreator(status) = group.status, status.isMember,
              group.usernames?.activeUsernames.isEmpty ?? true else { return false }
        let full = try await client.getSupergroupFullInfo(supergroupId: type.supergroupId)
        return full.description == importedSyncChannelDescription(ownerID) && full.memberCount == 1 && full.linkedChatId == 0
    }

    private func checkImportedSyncAccount(_ expected: String, client: TDLibClient) throws {
        try Task.checkCancellation()
        guard accountID == expected, self.client?.id == client.id else { throw ImportedPlaylistSyncError.accountChanged }
    }

    private func sendImportedSyncMessage(_ input: sending InputMessageContent, caption: String, chatID: Int64,
                                         expectedAccountID: String, client: TDLibClient) async throws -> Message {
        try checkImportedSyncAccount(expectedAccountID, client: client)
        let sent = try await client.sendMessage(chatId: chatID, inputMessageContent: input,
            options: nil, replyMarkup: nil, replyTo: nil, topicId: nil)
        if sent.sendingState == nil { return sent }
        // sendMessage often returns a temporary local ID before upload finishes.
        // Never remove outbox changes until a confirmed server message is seen.
        let deadline = Foundation.Date().addingTimeInterval(45)
        while Foundation.Date() < deadline {
            try checkImportedSyncAccount(expectedAccountID, client: client)
            let page = try await client.getChatHistory(chatId: chatID, fromMessageId: 0, limit: 100, offset: 0, onlyLocal: false)
            for message in page.messages ?? [] where TelegramMapping.text(from: message) == caption {
                if message.sendingState == nil { return message }
                if case let .messageSendingStateFailed(failure) = message.sendingState {
                    throw ServiceError.telegram(failure.error.message)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ImportedPlaylistSyncError.sendUnconfirmed
    }

    func cachedSearchBot(chatID: String) -> MusicChat? {
        searchBotPeers.values.first { $0.id == chatID }
    }

    func startListenTogether(in chat: MusicChat, presence: ListenTogetherPresence) async throws -> GroupCallPublishEndpoint {
        guard chat.kind != .user else { throw ServiceError.groupCallUnavailable }
        guard chat.canManageCalls == true || chat.isAdmin == true else {
            throw ServiceError.groupCallRequiresAdmin
        }
        let client = try await requireReadyClient()
        do {
            let callID = try await client.createVideoChat(
                chatId: chat.peerID,
                isRtmpStream: true,
                startDate: 0,
                title: presence.telegramTitle
            )
            let endpoint = try await client.getVideoChatRtmpUrl(chatId: chat.peerID)
            let call = try await client.getGroupCall(groupCallId: callID.id)
            return GroupCallPublishEndpoint(
                url: endpoint.url,
                key: endpoint.streamKey,
                call: GroupCallReference(
                    id: Int64(call.id),
                    accessHash: 0,
                    title: call.title,
                    participantCount: Int32(clamping: call.participantCount)
                )
            )
        } catch {
            throw ServiceError.telegram("Could not start Listen Together: \(error.localizedDescription)")
        }
    }

    func activeListenTogether(in chat: MusicChat) async throws -> GroupCallReference? {
        let client = try await requireReadyClient()
        let value = try await client.getChat(chatId: chat.peerID)
        guard value.videoChat.groupCallId > 0 else { return nil }
        let call = try await client.getGroupCall(groupCallId: value.videoChat.groupCallId)
        guard call.isActive, call.isRtmpStream,
              call.title.hasPrefix("♫ ") || call.title.hasPrefix("Ⅱ ") else { return nil }
        return groupCallReference(from: call)
    }

    func refreshListenTogether(_ call: GroupCallReference) async throws -> GroupCallReference? {
        let client = try await requireReadyClient()
        do {
            let result = try await client.getGroupCall(groupCallId: Int(call.id))
            return result.isActive ? groupCallReference(from: result) : nil
        } catch {
            return nil
        }
    }

    func updateListenTogetherTitle(_ call: GroupCallReference, title: String) async throws {
        let client = try await requireReadyClient()
        _ = try await client.setVideoChatTitle(groupCallId: Int(call.id), title: title)
    }

    func endListenTogether(_ call: GroupCallReference) async throws {
        let client = try await requireReadyClient()
        _ = try await client.endGroupCall(groupCallId: Int(call.id))
    }

    func listenTogetherInviteLink(for chat: MusicChat) async throws -> URL {
        let client = try await requireReadyClient()
        do {
            let result = try await client.createChatInviteLink(
                chatId: chat.peerID,
                createsJoinRequest: false,
                expirationDate: 0,
                memberLimit: 0,
                name: nil
            )
            guard let url = URL(string: result.inviteLink) else { throw ServiceError.inviteLinkUnavailable }
            return url
        } catch {
            throw ServiceError.telegram("Could not create a room invite link: \(error.localizedDescription)")
        }
    }

    func telegramContacts() async throws -> [MusicChat] {
        let client = try await requireReadyClient()
        let result = try await client.getContacts()
        var contacts: [MusicChat] = []
        for userID in result.userIds {
            guard let chat = try? await client.createPrivateChat(force: false, userId: userID),
                  var mapped = TelegramMapping.chat(from: chat) else { continue }
            if let user = try? await client.getUser(userId: userID) {
                mapped.username = user.usernames?.activeUsernames.first
            }
            contacts.append(mapped)
        }
        return contacts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func inviteContacts(_ contacts: [MusicChat], to chat: MusicChat, call: GroupCallReference) async throws -> Int {
        let client = try await requireReadyClient()
        let userIDs = Array(Set(contacts.filter { $0.kind == .user }.map(\.peerID)))
        guard !userIDs.isEmpty else { return 0 }
        do {
            let currentCall = try await client.getGroupCall(groupCallId: Int(call.id))
            guard currentCall.isActive else { throw ServiceError.groupCallUnavailable }
            _ = try await client.addChatMembers(chatId: chat.peerID, userIds: userIDs)
            return userIDs.count
        } catch {
            throw ServiceError.telegram("Could not invite contacts to Listen Together: \(error.localizedDescription)")
        }
    }

    func videoFolders() async throws -> [VideoFolder] {
        let client = try await requireReadyClient()
        let state = try await client.getCurrentState()
        for update in state.updates {
            if case let .updateChatFolders(value) = update {
                return value.chatFolders.map { VideoFolder(id: $0.id, title: $0.name.text.text) }
            }
        }
        return []
    }

    func videoChats(folderID: Int?) async throws -> [MusicChat] {
        let client = try await requireReadyClient()
        let list: ChatList? = folderID.map { .chatListFolder(ChatListFolder(chatFolderId: $0)) }
        // Load the folder itself, including rule-based members and archived chats.
        // Reading only includedChatIds would omit those members.
        for _ in 0..<100 {
            try Task.checkCancellation()
            do { _ = try await client.loadChats(chatList: list, limit: 100) }
            catch let error as TDLibKit.Error where error.code == 404 { break }
        }
        let result = try await client.getChats(chatList: list, limit: 10_000)
        var chats: [MusicChat] = []
        for id in result.chatIds {
            try Task.checkCancellation()
            let chat = try await client.getChat(chatId: id)
            if let value = TelegramMapping.chat(from: chat) { chats.append(value) }
        }
        return chats
    }

    func videos(in chatID: Int64, offsetID: Int64 = 0, query: String = "") async throws -> VideoPage {
        let requestID = UUID()
        let started = Foundation.Date()
        // Record stages without logging search text or message contents.
        PlaybackDiagnostics.log("video_list_start request=\(requestID) chat=\(chatID) offset=\(offsetID) queryLength=\(query.count)")
        defer { PlaybackDiagnostics.log("video_list_end request=\(requestID) elapsed=\(Foundation.Date().timeIntervalSince(started))") }
        do {
            try Task.checkCancellation()
            let client = try await requireReadyClient()
            try Task.checkCancellation()
            PlaybackDiagnostics.log("video_list_client_ready request=\(requestID) client=\(client.id) connection=\(connectionState)")
            var pages: [VideoPage] = []
            var isPartial = false
            // Include videos sent as documents. Advance using raw message IDs even
            // when a page contains only unrelated documents.
            for filter in [SearchMessagesFilter.searchMessagesFilterVideo, .searchMessagesFilterDocument] {
                try Task.checkCancellation()
                let filterName = filter == .searchMessagesFilterVideo ? "video" : "document"
                let searchStarted = Foundation.Date()
                PlaybackDiagnostics.log("video_list_search_start request=\(requestID) filter=\(filterName) connection=\(connectionState) timeout=30")
                // Do not race TDLib's async wrapper in a task group: its
                // continuation ignores cancellation, so the group could hang.
                do {
                    let page = try await VideoListRequest<VideoPage>.run { completion in
                        try client.searchChatMessages(
                            chatId: chatID, filter: filter, fromMessageId: offsetID,
                            limit: 30, offset: 0, query: query, senderId: nil, topicId: nil
                        ) { result in
                            completion(result.map { result in
                                let messages = result.messages.filter { offsetID == 0 || $0.id < offsetID }
                                return VideoPage(items: messages.compactMap(TelegramMapping.video(from:)), nextOffset: messages.map(\.id).min())
                            })
                            PlaybackDiagnostics.log("video_list_search_callback request=\(requestID) filter=\(filterName) elapsed=\(Foundation.Date().timeIntervalSince(searchStarted))")
                        }
                    }
                    try Task.checkCancellation()
                    PlaybackDiagnostics.log("video_list_search_complete request=\(requestID) filter=\(filterName) count=\(page.items.count) elapsed=\(Foundation.Date().timeIntervalSince(searchStarted))")
                    pages.append(page)
                } catch {
                    try Task.checkCancellation()
                    guard (error as? URLError)?.code == .timedOut,
                          pages.contains(where: { !$0.items.isEmpty }) else { throw error }
                    // A supplementary filter timing out must not discard the
                    // videos already loaded successfully by the first filter.
                    isPartial = true
                    PlaybackDiagnostics.log("video_list_partial request=\(requestID) filter=\(filterName) retryOffset=\(offsetID)", error: error)
                }
            }
            let page = VideoPageMerge.merge(pages, retryOffset: isPartial ? offsetID : nil)
            let next = page.nextOffset
            PlaybackDiagnostics.log("video_list_complete request=\(requestID) count=\(page.items.count) nextOffset=\(next ?? 0)")
            return page
        } catch {
            PlaybackDiagnostics.log("video_list_failed request=\(requestID) connection=\(connectionState)", error: error)
            throw error
        }
    }

    func videoPlaybackChoice(for original: VideoItem, prefer1080p: Bool) async throws -> VideoPlaybackChoice {
        let requestID = UUID()
        let started = Foundation.Date()
        // Bound the whole lookup, including all comment pages, rather than
        // allowing each of up to ten pages another full timeout interval.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        PlaybackDiagnostics.log("video_choice_start request=\(requestID) video=\(original.id) prefer1080p=\(prefer1080p) connection=\(connectionState)")
        defer { PlaybackDiagnostics.log("video_choice_end request=\(requestID) elapsed=\(Foundation.Date().timeIntervalSince(started))") }
        try Task.checkCancellation()
        let client = try await requireReadyClient()
        let lookupAccountID = accountID
        if prefer1080p, let cached = videoPlaybackChoices[original.id],
           Foundation.Date().timeIntervalSince(cached.date) < 60 {
            PlaybackDiagnostics.log("video_choice_cache_hit request=\(requestID) selected=\(cached.choice.selected.id)")
            return cached.choice
        }
        PlaybackDiagnostics.log("video_choice_original_start request=\(requestID)")
        let current: VideoItem?
        do {
            current = try await VideoListRequest<VideoItem?>.run(timeout: ContinuousClock.now.duration(to: deadline)) { completion in
                try client.getMessage(chatId: original.chatID, messageId: original.messageID) { result in
                    completion(result.map { TelegramMapping.video(from: $0) })
                }
            }
        } catch {
            PlaybackDiagnostics.log("video_choice_original_failed request=\(requestID) connection=\(connectionState)", error: error)
            throw error
        }
        try Task.checkCancellation()
        guard accountID == lookupAccountID else { throw CancellationError() }
        guard let current else { throw ServiceError.incompleteDownload }
        PlaybackDiagnostics.log("video_choice_original_complete request=\(requestID) video=\(current.id) fileID=\(current.fileID) width=\(current.width) height=\(current.height) duration=\(current.duration) episode=\(current.episode ?? "none") is1080p=\(current.is1080p) hasComments=\(current.hasComments)")
        var choice = VideoPlaybackChoice(original: current, selected: current)
        guard prefer1080p, !current.is1080p else { return choice }
        do {
            var lookup = VideoCommentLookup(original: current)
            PlaybackDiagnostics.log("video_comments_thread_start request=\(requestID) chat=\(current.chatID) message=\(current.messageID)")
            // Resolve both identifiers together before paging: channel posts and
            // their linked discussion roots have different message ID spaces.
            let thread = try await VideoListRequest<MessageThreadInfo>.run(timeout: ContinuousClock.now.duration(to: deadline)) { completion in
                try client.getMessageThread(chatId: current.chatID, messageId: current.messageID) { result in
                    if case let .failure(error) = result, let error = error as? TDLibKit.Error {
                        let message = error.code == 406 ? "suppressed" : String(error.message.prefix(512))
                        PlaybackDiagnostics.log("video_comments_thread_error request=\(requestID) tdlibCode=\(error.code) tdlibMessage=\(message.debugDescription)")
                    }
                    completion(result)
                }
            }
            try Task.checkCancellation()
            guard accountID == lookupAccountID else { throw CancellationError() }
            lookup.resolveThread(chatID: thread.chatId, messageID: thread.messageThreadId)
            PlaybackDiagnostics.log("video_comments_thread_complete request=\(requestID) chat=\(lookup.chatID) message=\(lookup.messageID)")
            var pageNumber = 0
            while lookup.canLoadMore {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                // The anchor and every cursor now belong to the discussion chat.
                let chatID = lookup.chatID
                let messageID = lookup.messageID
                let offset = lookup.offset
                pageNumber += 1
                let pageStarted = Foundation.Date()
                PlaybackDiagnostics.log("video_comments_page_start request=\(requestID) page=\(pageNumber) chat=\(chatID) message=\(messageID) offset=\(offset) limit=100 connection=\(connectionState) remaining=\(ContinuousClock.now.duration(to: deadline))")
                let videos = try await VideoListRequest<VideoPage>.run(timeout: ContinuousClock.now.duration(to: deadline)) { completion in
                    try client.getMessageThreadHistory(
                        chatId: chatID, fromMessageId: offset, limit: 100,
                        messageId: messageID, offset: 0
                    ) { result in
                        // NSError bridging drops TDLib's server code and message.
                        // Keep the request cursor so a failing page is identifiable.
                        if case let .failure(error) = result, let error = error as? TDLibKit.Error {
                            let message = error.code == 406 ? "suppressed" : String(error.message.prefix(512))
                            PlaybackDiagnostics.log("video_comments_page_error request=\(requestID) chat=\(chatID) message=\(messageID) offset=\(offset) tdlibCode=\(error.code) tdlibMessage=\(message.debugDescription) elapsed=\(Foundation.Date().timeIntervalSince(pageStarted))")
                        }
                        completion(result.map { page in
                            let rawMessages = page.messages ?? []
                            let messages = rawMessages.filter { offset == 0 || $0.id < offset }
                            // IDs from raw messages expose linked-chat responses and
                            // cursor filtering without logging unrelated comment text.
                            let ids = rawMessages.map { "\($0.chatId):\($0.id)" }.joined(separator: ",")
                            PlaybackDiagnostics.log("video_comments_page_response request=\(requestID) offset=\(offset) rawCount=\(rawMessages.count) filteredCount=\(messages.count) messages=[\(ids)] elapsed=\(Foundation.Date().timeIntervalSince(pageStarted))")
                            return VideoPage(items: messages.compactMap(TelegramMapping.video(from:)), nextOffset: messages.map(\.id).min())
                        })
                    }
                }
                try Task.checkCancellation()
                PlaybackDiagnostics.log("video_comments_page_complete request=\(requestID) videos=\(videos.items.count) nextOffset=\(videos.nextOffset ?? 0)")
                for candidate in videos.items {
                    // Ask the existing matcher rather than maintaining separate
                    // diagnostic matching rules that could drift from playback.
                    let matches = VideoItem.preferred1080p(in: [candidate], for: current) != nil
                    PlaybackDiagnostics.log("video_comments_candidate request=\(requestID) page=\(pageNumber) video=\(candidate.id) fileID=\(candidate.fileID) sameFile=\(candidate.fileID == current.fileID) sameMessage=\(candidate.id == current.id) width=\(candidate.width) height=\(candidate.height) is1080p=\(candidate.is1080p) duration=\(candidate.duration) durationDelta=\(abs(candidate.duration - current.duration)) durationTolerance=\(max(10, current.duration * 0.02)) episode=\(candidate.episode ?? "none") originalEpisode=\(current.episode ?? "none") matches=\(matches) eligible=\(matches && candidate.fileID != current.fileID) size=\(candidate.size) fileName=\(String(candidate.fileName.prefix(160)).debugDescription) title=\(String(candidate.title.prefix(160)).debugDescription)")
                }
                if let selected = lookup.consume(videos) {
                    PlaybackDiagnostics.log("video_comments_selected request=\(requestID) page=\(pageNumber) video=\(selected.id)")
                    choice.selected = selected
                    break
                }
                PlaybackDiagnostics.log("video_comments_continue request=\(requestID) page=\(pageNumber) canLoadMore=\(lookup.canLoadMore) nextOffset=\(lookup.offset)")
            }
            // Share the metadata lookup between the list and playback. Never
            // cache access errors, so clicking a row can retry a failed lookup.
            guard accountID == lookupAccountID else { throw CancellationError() }
            videoPlaybackChoices[current.id] = (Foundation.Date(), choice)
        } catch is CancellationError {
            PlaybackDiagnostics.log("video_comments_cancelled request=\(requestID)")
            throw CancellationError()
        }
        catch {
            PlaybackDiagnostics.log("video_comments_fallback request=\(requestID) connection=\(connectionState)", error: error)
            choice.commentsUnavailable = true
        }
        PlaybackDiagnostics.log("video_choice_complete request=\(requestID) selected=\(choice.selected.id) commentsUnavailable=\(choice.commentsUnavailable)")
        return choice
    }

    func beginVideoPlayback(_ video: VideoItem, expectedAccountID: String) throws -> UUID {
        guard accountID == expectedAccountID else { throw CancellationError() }
        let token = UUID()
        videoSessions[token] = video.fileID
        let key = "video.bufferedFiles.\(accountID)"
        var ids = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        ids.insert(video.fileID)
        UserDefaults.standard.set(Array(ids), forKey: key)
        return token
    }

    func endVideoPlayback(_ token: UUID) async {
        videoDownloadWindows.removeValue(forKey: token)
        guard let fileID = videoSessions.removeValue(forKey: token),
              !videoSessions.values.contains(fileID), let client else { return }
        _ = try? await client.cancelDownloadFile(fileId: fileID, onlyIfPending: false)
    }

    func clearVideoBuffers() async throws {
        let client = try await requireReadyClient()
        let key = "video.bufferedFiles.\(accountID)"
        let ids = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        var failed: [Int] = []
        for id in ids {
            guard !videoSessions.values.contains(id) else { failed.append(id); continue }
            do { _ = try await client.deleteFile(fileId: id) }
            catch { failed.append(id) }
        }
        UserDefaults.standard.set(failed, forKey: key)
        if !failed.isEmpty { throw ServiceError.telegram("Some video buffers could not be cleared. Try again after closing video playback.") }
    }

    func videoBytes(_ video: VideoItem, session: UUID, offset: Int64, length: Int32) async throws -> Data {
        guard offset >= 0, length > 0, offset < video.size else { return Data() }
        let client = try await requireReadyClient()
        guard videoSessions[session] == video.fileID else { throw CancellationError() }
        let count = min(Int64(length), video.size - offset)
        await fileDownloadGate.acquire(fileID: video.fileID, priority: .playback)
        do {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                guard videoSessions[session] == video.fileID else { throw CancellationError() }
                do {
                    var file = try await client.getFile(fileId: video.fileID)
                    if let bytes = try await bufferedVideoBytes(file, offset: offset, length: count, client: client).data {
                        await fileDownloadGate.release(fileID: video.fileID)
                        return bytes
                    }
                    let window = videoDownloadWindows[session]
                    if attempt > 0 || !file.local.isDownloadingActive || window?.contains(offset: offset, length: count) != true {
                        let next = VideoBufferWindow(offset: offset, fileSize: video.size)
                        PlaybackDiagnostics.log("video_window_start fileID=\(video.fileID) offset=\(next.offset) length=\(next.length) attempt=\(attempt)")
                        // Keep a bounded continuous transfer running. Waiting for
                        // synchronous:true here can hold the gate indefinitely.
                        file = try await client.downloadFile(
                            fileId: video.fileID, limit: next.length, offset: next.offset,
                            priority: 32, synchronous: false
                        )
                        guard videoSessions[session] == video.fileID else { throw CancellationError() }
                        videoDownloadWindows[session] = next
                    }
                    var progress = VideoDownloadProgress(now: ProcessInfo.processInfo.systemUptime)
                    while true {
                        try Task.checkCancellation()
                        guard videoSessions[session] == video.fileID else { throw CancellationError() }
                        let buffered = try await bufferedVideoBytes(file, offset: offset, length: count, client: client)
                        if let data = buffered.data {
                            PlaybackDiagnostics.log("video_range_complete fileID=\(video.fileID) offset=\(offset) length=\(count)")
                            await fileDownloadGate.release(fileID: video.fileID)
                            return data
                        }
                        if progress.timedOut(available: buffered.available, now: ProcessInfo.processInfo.systemUptime) {
                            throw URLError(.timedOut)
                        }
                        try await Task.sleep(for: .milliseconds(50))
                        file = try await client.getFile(fileId: video.fileID)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard videoSessions[session] == video.fileID else { throw CancellationError() }
                    PlaybackDiagnostics.log("video_range_retry fileID=\(video.fileID) offset=\(offset) attempt=\(attempt)", error: error)
                    let timeout = (error as? URLError)?.code == .timedOut
                    guard attempt < 2, timeout || isDownloadCancelled(error) || isIncompleteDownload(error) else { throw error }
                    _ = try? await client.cancelDownloadFile(fileId: video.fileID, onlyIfPending: false)
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw ServiceError.incompleteDownload
        } catch {
            await fileDownloadGate.release(fileID: video.fileID)
            if error is CancellationError { throw CancellationError() }
            throw readableDownloadError(error)
        }
    }

    private func bufferedVideoBytes(
        _ file: File, offset: Int64, length: Int64, client: TDLibClient
    ) async throws -> (data: Data?, available: Int64) {
        // Sparse files can be large while the requested range is missing. Ask
        // TDLib about this exact offset before reading previously cached seeks.
        let available: Int64
        if file.local.isDownloadingCompleted { available = max(0, file.size - offset) }
        else {
            available = try await client.getFileDownloadedPrefixSize(fileId: file.id, offset: offset).size
        }
        guard available >= length, !file.local.path.isEmpty else { return (nil, available) }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.local.path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else { throw ServiceError.incompleteDownload }
        return (data, available)
    }

    func hasMusic(in chat: MusicChat) async throws -> Bool {
        try await !searchMusic(in: chat, query: "", limit: 1).isEmpty
    }

    func comments(for track: Track, in chat: MusicChat) async throws -> [TrackComment] {
        guard let chatID = TelegramMapping.chatID(from: chat.id) else { return [] }
        let client = try await requireReadyClient()
        do {
            let result = try await client.getMessageThreadHistory(
                chatId: chatID,
                fromMessageId: 0,
                limit: 100,
                messageId: track.messageID,
                offset: 0
            )
            return (result.messages ?? []).compactMap(TelegramMapping.comment(from:)).sorted { $0.date < $1.date }
        } catch {
            throw ServiceError.commentingUnavailable
        }
    }

    func addComment(_ rawText: String, to track: Track, in chat: MusicChat) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chatID = TelegramMapping.chatID(from: chat.id) else {
            throw ServiceError.commentingUnavailable
        }
        let client = try await requireReadyClient()
        let reply = InputMessageReplyTo.inputMessageReplyToMessage(
            InputMessageReplyToMessage(
                checklistTaskId: 0,
                messageId: track.messageID,
                pollOptionId: "",
                quote: nil
            )
        )
        let input = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: false,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        do {
            _ = try await client.sendMessage(
                chatId: chatID,
                inputMessageContent: input,
                options: nil,
                replyMarkup: nil,
                replyTo: reply,
                topicId: nil
            )
        } catch {
            throw ServiceError.commentingUnavailable
        }
    }

    func loadPlaylistChats(from chats: [MusicChat], folderName: String) async throws -> [MusicChat] {
        let normalizedName = PlaylistFolderConfiguration.normalizedName(folderName) ?? PlaylistFolderConfiguration.defaultName
        let client = try await requireReadyClient()
        guard let folderID = try await existingPlaylistFolderID(named: normalizedName, client: client) else { return [] }
        let folder = try await client.getChatFolder(chatFolderId: folderID)
        let included = Set(folder.includedChatIds)
        return chats.filter { included.contains($0.peerID) && $0.kind == .channel }
    }

    func createPlaylist(named rawName: String) async throws -> MusicChat {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError.playlistCreationFailed }
        let client = try await requireReadyClient()
        do {
            let chat = try await client.createNewSupergroupChat(
                description: "",
                forImport: false,
                isChannel: true,
                isForum: false,
                location: nil,
                messageAutoDeleteTime: 0,
                title: name
            )
            guard let result = TelegramMapping.chat(from: chat) else { throw ServiceError.playlistCreationFailed }
            return result
        } catch {
            throw ServiceError.telegram("Could not create playlist: \(error.localizedDescription)")
        }
    }

    func addToPlaylistFolder(_ playlist: MusicChat, folderName: String) async throws {
        guard let name = PlaylistFolderConfiguration.normalizedName(folderName), playlist.kind == .channel else {
            throw ServiceError.playlistFolderFailed
        }
        let client = try await requireReadyClient()
        let key = playlistFolderKey(name)
        do {
            if let folderID = try await existingPlaylistFolderID(named: name, client: client) {
                let existing = try await client.getChatFolder(chatFolderId: folderID)
                let updated = ChatFolder(
                    colorId: existing.colorId,
                    excludeArchived: existing.excludeArchived,
                    excludeMuted: existing.excludeMuted,
                    excludeRead: existing.excludeRead,
                    excludedChatIds: existing.excludedChatIds,
                    icon: existing.icon,
                    includeBots: existing.includeBots,
                    includeChannels: existing.includeChannels,
                    includeContacts: existing.includeContacts,
                    includeGroups: existing.includeGroups,
                    includeNonContacts: existing.includeNonContacts,
                    includedChatIds: Array(Set(existing.includedChatIds + [playlist.peerID])).sorted(),
                    isShareable: existing.isShareable,
                    name: existing.name,
                    pinnedChatIds: existing.pinnedChatIds
                )
                _ = try await client.editChatFolder(chatFolderId: folderID, folder: updated)
            } else {
                let title = FormattedText(entities: [], text: name)
                let folder = ChatFolder(
                    colorId: -1,
                    excludeArchived: false,
                    excludeMuted: false,
                    excludeRead: false,
                    excludedChatIds: [],
                    icon: nil,
                    includeBots: false,
                    includeChannels: false,
                    includeContacts: false,
                    includeGroups: false,
                    includeNonContacts: false,
                    includedChatIds: [playlist.peerID],
                    isShareable: false,
                    name: ChatFolderName(animateCustomEmoji: false, text: title),
                    pinnedChatIds: []
                )
                let created = try await client.createChatFolder(folder: folder)
                UserDefaults.standard.set(created.id, forKey: key)
            }
        } catch {
            throw ServiceError.telegram("Could not add the playlist folder: \(error.localizedDescription)")
        }
    }

    func deletePlaylist(_ playlist: MusicChat) async throws {
        guard playlist.kind == .channel else { throw ServiceError.playlistDeletionUnavailable }
        let client = try await requireReadyClient()
        do {
            _ = try await client.deleteChat(chatId: playlist.peerID)
        } catch {
            throw ServiceError.telegram("Could not delete the playlist: \(error.localizedDescription)")
        }
    }

    func delete(_ track: Track, from playlist: MusicChat) async throws {
        guard track.chatID == playlist.id else { throw ServiceError.playlistTrackDeletionUnavailable }
        let client = try await requireReadyClient()
        _ = try await client.deleteMessages(
            chatId: playlist.peerID,
            messageIds: [track.messageID],
            revoke: true
        )
    }

    func rename(_ playlist: MusicChat, to title: String) async throws {
        guard playlist.kind == .channel else { throw ServiceError.playlistRenameUnavailable }
        let client = try await requireReadyClient()
        _ = try await client.setChatTitle(chatId: playlist.peerID, title: title)
    }

    func save(_ track: Track, from source: MusicChat, to playlist: MusicChat) async throws {
        let client = try await requireReadyClient()
        guard let sourceChatID = TelegramMapping.chatID(from: source.id) else {
            throw ServiceError.playlistCreationFailed
        }
        let sourceMessageID: Int64
        if track.messageID > 0 {
            sourceMessageID = track.messageID
        } else if let currentTrack = await currentTelegramTrack(for: track, in: sourceChatID, client: client) {
            sourceMessageID = currentTrack.messageID
        } else {
            throw ServiceError.telegram("Telegram could not find the source song message.")
        }

        let properties: MessageProperties
        do {
            properties = try await client.getMessageProperties(
                chatId: sourceChatID,
                messageId: sourceMessageID
            )
        } catch {
            throw readablePlaylistSaveError(error)
        }
        if properties.canBeForwarded {
            do {
                let result = try await client.forwardMessages(
                    chatId: playlist.peerID,
                    fromChatId: sourceChatID,
                    messageIds: [sourceMessageID],
                    options: nil,
                    removeCaption: false,
                    sendCopy: false,
                    topicId: nil
                )
                if result.messages?.contains(where: { $0.chatId == playlist.peerID }) == true { return }
            } catch {
                guard properties.canBeCopied else { throw readablePlaylistSaveError(error) }
            }
        }

        guard properties.canBeCopied else {
            throw ServiceError.telegram("Telegram does not allow this song to be forwarded or copied to a playlist.")
        }
        let copied: Messages
        do {
            copied = try await client.forwardMessages(
                chatId: playlist.peerID,
                fromChatId: sourceChatID,
                messageIds: [sourceMessageID],
                options: nil,
                removeCaption: false,
                sendCopy: true,
                topicId: nil
            )
        } catch {
            throw readablePlaylistSaveError(error)
        }
        guard copied.messages?.contains(where: { $0.chatId == playlist.peerID }) == true else {
            throw ServiceError.telegram("Telegram did not add the song to the playlist.")
        }
    }

    func upvote(_ track: Track, in chat: MusicChat) async throws {
        let client = try await requireReadyClient()
        let reaction = ReactionType.reactionTypeEmoji(ReactionTypeEmoji(emoji: "👍"))
        _ = try await client.addMessageReaction(
            chatId: chat.peerID,
            isBig: false,
            messageId: track.messageID,
            reactionType: reaction,
            updateRecentReactions: true
        )
    }

    func download(
        _ track: Track,
        to destination: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        guard let fileID = await resolvedFileID(for: track) else {
            throw ServiceError.incompleteDownload
        }
        await progress(0)
        do {
            let data: Data
            do {
                data = try await downloadFile(fileID: fileID, offset: 0, limit: 0)
            } catch {
                guard isFileNotFound(error) || isIncompleteDownload(error),
                      let latestFileID = await refreshedFileID(for: track),
                      latestFileID != fileID else { throw error }
                refreshedFileIDs[track.id] = latestFileID
                data = try await downloadFile(fileID: latestFileID, offset: 0, limit: 0)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            await progress(1)
        } catch {
            throw readableDownloadError(error)
        }
    }

    func stream(
        _ track: Track,
        sourceChat: MusicChat? = nil,
        offset requestedOffset: Int64,
        length requestedLength: Int32
    ) async throws -> Data {
        try await stream(
            track,
            sourceChat: sourceChat,
            offset: requestedOffset,
            length: requestedLength,
            priority: .playback
        )
    }

    func streamForDownload(
        _ track: Track,
        sourceChat: MusicChat? = nil,
        offset requestedOffset: Int64,
        length requestedLength: Int32
    ) async throws -> Data {
        try await stream(
            track,
            sourceChat: sourceChat,
            offset: requestedOffset,
            length: requestedLength,
            priority: .background
        )
    }

    private func stream(
        _ track: Track,
        sourceChat: MusicChat?,
        offset requestedOffset: Int64,
        length requestedLength: Int32,
        priority: AudioTransferPriority
    ) async throws -> Data {
        guard requestedOffset >= 0,
              let fileID = await resolvedFileID(for: track) else {
            PlaybackDiagnostics.log("telegram_resolve_failed track=\(track.id) offset=\(requestedOffset) length=\(requestedLength)", error: ServiceError.incompleteDownload)
            throw ServiceError.incompleteDownload
        }
        if requestedLength <= 0 { return Data() }
        do {
            return try await downloadFile(
                fileID: fileID,
                offset: requestedOffset,
                limit: Int64(requestedLength),
                priority: priority
            )
        } catch {
            PlaybackDiagnostics.log("telegram_stream_failed track=\(track.id) fileID=\(fileID) offset=\(requestedOffset) length=\(requestedLength) priority=\(priority)", error: error)
            guard isFileNotFound(error) || isIncompleteDownload(error),
                  let latestFileID = await refreshedFileID(for: track),
                  latestFileID != fileID else {
                PlaybackDiagnostics.log("telegram_refresh_unavailable track=\(track.id) fileID=\(fileID)")
                throw readableDownloadError(error)
            }
            PlaybackDiagnostics.log("telegram_refresh_file track=\(track.id) oldFileID=\(fileID) newFileID=\(latestFileID)")
            refreshedFileIDs[track.id] = latestFileID
            do {
                return try await downloadFile(
                    fileID: latestFileID,
                    offset: requestedOffset,
                    limit: Int64(requestedLength),
                    priority: priority
                )
            } catch {
                PlaybackDiagnostics.log("telegram_retry_failed track=\(track.id) fileID=\(latestFileID) offset=\(requestedOffset) length=\(requestedLength)", error: error)
                throw readableDownloadError(error)
            }
        }
    }

    func artwork(for track: Track) async throws -> Data? {
        guard let chatID = TelegramMapping.chatID(from: track.chatID) else { return nil }
        let client = try await requireReadyClient()
        guard let message = try? await client.getMessage(chatId: chatID, messageId: track.messageID) else { return nil }
        let thumbnail: Thumbnail?
        switch message.content {
        case let .messageAudio(value):
            thumbnail = value.audio.albumCoverThumbnail ?? value.audio.externalAlbumCovers.first
        case let .messageDocument(value):
            thumbnail = value.document.thumbnail
        default:
            thumbnail = nil
        }
        guard let fileID = thumbnail?.file.id else { return nil }
        return try? await downloadFile(fileID: fileID, offset: 0, limit: 0)
    }

    func avatar(for chat: MusicChat) async throws -> Data? {
        let client = try await requireReadyClient()
        guard let value = try? await client.getChat(chatId: chat.peerID),
              let photo = value.photo else { return nil }
        return try? await downloadFile(fileID: photo.small.id, offset: 0, limit: 0)
    }

    func avatar(for account: TelegramAccount) async throws -> Data? {
        let client = try await requireReadyClient()
        guard let user = try? await client.getMe(), let photo = user.profilePhoto else { return nil }
        return try? await downloadFile(fileID: photo.big.id, offset: 0, limit: 0)
    }

    func logOut() async {
        if let client {
            _ = try? await client.logOut()
        }
        await closeClient()
        authorizationState = nil
        _ = keychain.setTDLibAccount(accountID, authorized: false)
        UserDefaults.standard.set(false, forKey: authorizationDefaultsKey)
    }

    func discardSession() async {
        await closeClient()
        removeTDLibStorage(for: accountID)
        authorizationState = nil
        _ = keychain.setTDLibAccount(accountID, authorized: false)
    }

    private func requireClient() async throws -> TDLibClient {
        guard !replacingSession, !reconnectingClient, closingClientID == nil else { throw ServiceError.noConnection }
        if let client { return client }
        guard let credentials else { throw ServiceError.notConfigured }
        let directory = storageURL(for: accountID)
        let existingFiles: [String]
        if FileManager.default.fileExists(atPath: directory.path) {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                throw ServiceError.sessionPersistenceFailed
            }
            existingFiles = files
        } else {
            existingFiles = []
        }
        let hasDatabase = existingFiles.contains { $0.hasPrefix("td.binlog") || $0.hasPrefix("db.sqlite") }
        // Never generate a replacement key for an existing encrypted database.
        let storedKey = hasDatabase
            ? keychain.loadTDLibDatabaseKey(accountID: accountID)
            : keychain.loadOrCreateTDLibDatabaseKey(accountID: accountID)
        guard let databaseKey = storedKey else {
            throw ServiceError.sessionPersistenceFailed
        }
        let filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        } catch {
            throw ServiceError.sessionPersistenceFailed
        }
        let initializationAccountID = accountID
        let manager = self.manager ?? TDLibClientManager()
        self.manager = manager
        let created = manager.createClient(updateHandler: { [weak self] data, sourceClient in
            let sourceID = sourceClient.id
            Task.detached { [weak self, data] in await self?.receiveClientUpdate(data, from: sourceID) }
        })
        proxyClientReady = false
        client = created
        var initializationStage = "getAuthorizationState"
        do {
            var state = try await created.getAuthorizationState()
            guard client?.id == created.id, accountID == initializationAccountID else { throw CancellationError() }
            if case .authorizationStateWaitTdlibParameters = state {
                #if os(iOS)
                let deviceModel = "iPhone"
                #elseif os(macOS)
                let deviceModel = "Mac"
                #else
                let deviceModel = "Apple device"
                #endif
                initializationStage = "setTdlibParameters"
                _ = try await created.setTdlibParameters(
                    apiHash: credentials.apiHash,
                    apiId: Int(credentials.apiID),
                    applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    databaseDirectory: directory.path,
                    databaseEncryptionKey: databaseKey,
                    deviceModel: deviceModel,
                    filesDirectory: filesDirectory.path,
                    systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,
                    useTestDc: false
                )
                initializationStage = "getAuthorizationStateAfterParameters"
                state = try await created.getAuthorizationState()
            }
            guard client?.id == created.id, accountID == initializationAccountID else { throw CancellationError() }
            // TDLib needs its database parameters before proxy configuration;
            // apply before issuing any login or media request.
            proxyClientReady = true
            initializationStage = "applyConnectionProxy"
            try await setConnectionProxy(desiredProxy)
            guard client?.id == created.id, accountID == initializationAccountID else { throw CancellationError() }
            authorizationState = state
            if case .authorizationStateReady = state {
                _ = keychain.setTDLibAccount(accountID, authorized: true)
            }
            return created
        } catch {
            // An account change may close this client while initialization is
            // awaiting TDLib. Never clear the new account's client in that case.
            guard client?.id == created.id, accountID == initializationAccountID else {
                PlaybackDiagnostics.log("telegram_client_initialization_cancelled reason=clientChanged")
                throw CancellationError()
            }
            // TDLibKit.Error does not implement LocalizedError; bridging it to
            // NSError loses both its real code and message. Preserve them here.
            let tdlibCode = (error as? TDLibKit.Error).map { String($0.code) } ?? "none"
            let readableError = readableLoginError(error)
            PlaybackDiagnostics.log("telegram_client_initialization_failed stage=\(initializationStage) tdlibCode=\(tdlibCode)", error: readableError)
            client = nil
            proxyClientReady = false
            _ = try? await created.close()
            throw readableLoginError(error)
        }
    }

    private func requireReadyClient() async throws -> TDLibClient {
        let client = try await requireClient()
        let state = try await client.getAuthorizationState()
        guard self.client?.id == client.id else { throw CancellationError() }
        authorizationState = state
        guard case .authorizationStateReady = state else { throw ServiceError.noConnection }
        return client
    }

    private func waitForAuthorizationState(
        _ matches: (AuthorizationState) -> Bool
    ) async throws -> AuthorizationState {
        let client = try await requireClient()
        for _ in 0..<60 {
            try Task.checkCancellation()
            let state = try await client.getAuthorizationState()
            authorizationState = state
            if matches(state) { return state }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ServiceError.noConnection
    }

    private func authenticationResultAfterCodeRequest() async throws -> RequestCodeResult {
        let state = try await waitForAuthorizationState { state in
            switch state {
            case .authorizationStateWaitCode, .authorizationStateWaitEmailAddress,
                 .authorizationStateWaitPassword, .authorizationStateWaitPremiumPurchase,
                 .authorizationStateWaitRegistration, .authorizationStateReady:
                true
            default:
                false
            }
        }
        switch state {
        case let .authorizationStateWaitCode(value):
            return .code(hint: String(describing: value.codeInfo.type), isEmail: false)
        case .authorizationStateWaitEmailAddress:
            return .emailSetup
        case let .authorizationStateWaitPassword(value):
            return .password(hint: value.passwordHint)
        case let .authorizationStateWaitPremiumPurchase(value):
            throw ServiceError.paidAuthorizationRequired(value.supportEmailAddress)
        case .authorizationStateWaitRegistration:
            throw ServiceError.signUpRequired
        case .authorizationStateReady:
            return .ready(try await acceptAuthorization())
        default:
            throw ServiceError.invalidCodeResponse
        }
    }

    private func acceptAuthorization() async throws -> TelegramAccount {
        let client = try await requireClient()
        let account = TelegramMapping.account(from: try await client.getMe(), accountID: accountID)
        authorizationState = .authorizationStateReady
        UserDefaults.standard.set(true, forKey: authorizationDefaultsKey)
        guard keychain.setTDLibAccount(accountID, authorized: true) else {
            throw ServiceError.sessionPersistenceFailed
        }
        return account
    }

    func recoverConnectionAfterStandby() async throws {
        guard !replacingSession, !reconnectingClient, closingClientID == nil,
              proxyClientReady, let previousClient = client,
              case .authorizationStateReady? = authorizationState,
              ["connectionStateConnecting", "connectionStateConnectingToProxy"].contains(connectionState) else { return }
        let expectedAccountID = accountID
        let expectedClientID = previousClient.id
        PlaybackDiagnostics.log("telegram_foreground_reconnect_grace client=\(expectedClientID) state=\(connectionState)")
        try await Task.sleep(for: .seconds(5))
        // TDLib may have recovered while we waited, or the user may have changed
        // accounts. Never disrupt a healthy/updating connection or a new client.
        guard !replacingSession, !reconnectingClient, closingClientID == nil,
              accountID == expectedAccountID, client?.id == expectedClientID,
              ["connectionStateConnecting", "connectionStateConnectingToProxy"].contains(connectionState) else { return }
        reconnectingClient = true
        defer { reconnectingClient = false }
        closingClientID = expectedClientID
        client = nil
        proxyClientReady = false
        connectionState = "connectionStateConnecting"
        PlaybackDiagnostics.log("telegram_foreground_reconnect_start client=\(expectedClientID)")
        // A close result acknowledges the request, not the end of database use.
        // Keep media session handles: the reopened client uses the same database.
        do {
            _ = try await VideoListRequest<Void>.run(timeout: .seconds(5)) { completion in
                try previousClient.close { result in completion(result.map { _ in () }) }
            }
        } catch {
            PlaybackDiagnostics.log("telegram_foreground_close_request_failed", error: readableLoginError(error))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while closingClientID == expectedClientID, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard closingClientID == nil else {
            // Keep initialization gated until a late Closed update arrives.
            // Opening the same database while it is closing risks a file lock.
            PlaybackDiagnostics.log("telegram_foreground_reconnect_deferred reason=closeTimeout")
            throw ServiceError.noConnection
        }
        try Task.checkCancellation()
        guard accountID == expectedAccountID, !replacingSession, client == nil else { return }
        reconnectingClient = false
        let reopened = try await requireReadyClient()
        PlaybackDiagnostics.log("telegram_foreground_reconnect_reopened client=\(reopened.id) state=\(connectionState)")
    }

    private func receiveClientUpdate(_ data: Data, from sourceID: Int32) {
        guard client?.id == sourceID else {
            // The old client remains capable of delivering queued callbacks.
            // Only its final Closed acknowledgement belongs to the recovery.
            if closingClientID == sourceID,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["@type"] as? String == "updateAuthorizationState",
               let state = object["authorization_state"] as? [String: Any],
               state["@type"] as? String == "authorizationStateClosed" {
                closingClientID = nil
                PlaybackDiagnostics.log("telegram_foreground_client_closed client=\(sourceID)")
            }
            return
        }
        receiveUpdate(data)
    }

    // Read TDLib's actual state without starting another connection or request.
    func videoConnectionState() -> String { connectionState }

    func connectionStateUpdates() -> AsyncStream<String> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connectionStateObservers[id] = continuation
            // Subscribe and send the initial value on the same actor to avoid gaps.
            continuation.yield(connectionState)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeConnectionStateObserver(id) }
            }
        }
    }

    private func removeConnectionStateObserver(_ id: UUID) {
        connectionStateObservers.removeValue(forKey: id)
    }

    private func receiveUpdate(_ data: Data) {
        guard let client, let update = try? client.decoder.decode(Update.self, from: data) else { return }
        if case let .updateConnectionState(value) = update {
            connectionState = String(describing: value.state)
            PlaybackDiagnostics.log("telegram_connection_state client=\(client.id) state=\(connectionState)")
            return
        }
        guard case let .updateAuthorizationState(value) = update else { return }
        authorizationState = value.authorizationState
        switch value.authorizationState {
        case .authorizationStateWaitOtherDeviceConfirmation,
             .authorizationStateWaitPassword,
             .authorizationStateWaitRegistration,
             .authorizationStateReady:
            loginTokenUpdateRevision &+= 1
        default:
            break
        }
        if case .authorizationStateReady = value.authorizationState {
            UserDefaults.standard.set(true, forKey: authorizationDefaultsKey)
            _ = keychain.setTDLibAccount(accountID, authorized: true)
        }
    }

    private func resolveSearchBot(_ config: SearchBotConfig) async throws -> MusicChat {
        if let cached = searchBotPeers[config.normalizedBotName.lowercased()] { return cached }
        let client = try await requireReadyClient()
        let name = config.normalizedBotName
        do {
            let chat = try await client.searchPublicChat(username: name)
            guard case let .chatTypePrivate(value) = chat.type,
                  let user = try? await client.getUser(userId: value.userId),
                  let mapped = TelegramMapping.chat(
                    from: chat,
                    username: user.usernames?.activeUsernames.first
                  ) else {
                throw ServiceError.invalidSearchBot(config.displayBotName)
            }
            searchBotPeers[name.lowercased()] = mapped
            return mapped
        } catch {
            if error is ServiceError { throw error }
            throw ServiceError.invalidSearchBot(config.displayBotName)
        }
    }

    private func botHistoryMessages(client: TDLibClient, chatID: Int64, limit: Int) async throws -> [Message] {
        let result = try await client.getChatHistory(
            chatId: chatID,
            fromMessageId: 0,
            limit: max(1, limit),
            offset: 0,
            onlyLocal: false
        )
        return result.messages ?? []
    }

    private func waitForBotResponse(
        config: SearchBotConfig,
        comparedWith baseline: [BotSearchMessage],
        limit: Int32,
        settleForAudio: Bool
    ) async throws -> [BotSearchMessage] {
        let previous = Dictionary(
            baseline.lazy.filter { !$0.isOutgoing }.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var latest = baseline
        for delay in [150, 250, 400, 650, 1_000, 1_600, 2_500] {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(delay))
            latest = try await botSearchHistory(config: config, limit: limit)
            let current = Dictionary(
                latest.lazy.filter { !$0.isOutgoing }.map { ($0.id, $0) },
                uniquingKeysWith: { _, message in message }
            )
            guard current != previous else { continue }
            guard settleForAudio, !containsNewBotTrack(current, comparedWith: previous) else {
                return latest
            }

            try await Task.sleep(for: .milliseconds(700))
            var settled = try await botSearchHistory(config: config, limit: limit)
            let settledIncoming = Dictionary(
                settled.lazy.filter { !$0.isOutgoing }.map { ($0.id, $0) },
                uniquingKeysWith: { _, message in message }
            )
            if containsNewBotTrack(settledIncoming, comparedWith: previous) { return settled }

            try await Task.sleep(for: .milliseconds(1_300))
            let final = try await botSearchHistory(config: config, limit: limit)
            let finalIncoming = Dictionary(
                final.lazy.filter { !$0.isOutgoing }.map { ($0.id, $0) },
                uniquingKeysWith: { _, message in message }
            )
            if finalIncoming != settledIncoming { settled = final }
            return settled
        }
        return latest
    }

    private func containsNewBotTrack(
        _ messages: [Int64: BotSearchMessage],
        comparedWith baseline: [Int64: BotSearchMessage]
    ) -> Bool {
        messages.contains { id, message in
            guard let track = message.track else { return false }
            return baseline[id]?.track != track
        }
    }

    private func readableBotButtonError(_ error: Swift.Error, botName: String) -> Swift.Error {
        if error is ServiceError || error is CancellationError { return error }
        guard let error = error as? TDLibKit.Error else {
            return ServiceError.telegram("Telegram could not process the choice for \(botName): \(error.localizedDescription)")
        }
        let detail = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = detail.uppercased()
        if uppercased.contains("MESSAGE_ID_INVALID") || uppercased.contains("BUTTON_DATA_INVALID") {
            return ServiceError.telegram("That bot result expired. Run the search again and choose a fresh result.")
        }
        if error.code == 406 {
            return ServiceError.telegram("Telegram could not process the choice for \(botName) (error 406).")
        }
        let suffix = detail.isEmpty ? "TDLib error \(error.code)" : "TDLib \(error.code): \(detail)"
        return ServiceError.telegram("Telegram could not process the choice for \(botName) (\(suffix)).")
    }

    private func readablePlaylistSaveError(_ error: Swift.Error) -> Swift.Error {
        if error is ServiceError || error is CancellationError { return error }
        guard let error = error as? TDLibKit.Error else { return error }
        guard error.code != 406 else {
            return ServiceError.telegram("Telegram could not add this song to the playlist (error 406).")
        }
        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = message.uppercased()
        if uppercased.contains("MESSAGE_ID_INVALID") {
            return ServiceError.telegram("The source song message is no longer available. Search again and retry.")
        }
        if uppercased.contains("CHAT_WRITE_FORBIDDEN") || uppercased.contains("CHANNEL_PRIVATE") {
            return ServiceError.telegram("Telegram does not allow adding songs to this playlist.")
        }
        let suffix = message.isEmpty ? "TDLib error \(error.code)" : "TDLib \(error.code): \(message)"
        return ServiceError.telegram("Telegram could not add this song to the playlist (\(suffix)).")
    }

    private func groupCallReference(from call: GroupCall) -> GroupCallReference {
        GroupCallReference(
            id: Int64(call.id),
            accessHash: 0,
            title: call.title,
            participantCount: Int32(clamping: call.participantCount)
        )
    }

    private func downloadFile(
        fileID: Int,
        offset: Int64,
        limit: Int64,
        priority: AudioTransferPriority = .background
    ) async throws -> Data {
        let client = try await requireReadyClient()
        var cancellationRetries = 0
        while true {
            await fileDownloadGate.acquire(fileID: fileID, priority: priority)
            do {
                try Task.checkCancellation()
                PlaybackDiagnostics.log("telegram_range_start fileID=\(fileID) offset=\(offset) length=\(limit) priority=\(priority) retry=\(cancellationRetries)")
                let file = try await client.downloadFile(
                    fileId: fileID,
                    limit: limit,
                    offset: offset,
                    priority: 32,
                    synchronous: true
                )
                let data: Data
                do {
                    data = try readLocalFile(file, offset: offset, limit: limit)
                } catch let error as ServiceError {
                    guard isIncompleteDownload(error), limit > 0 else { throw error }
                    PlaybackDiagnostics.log("telegram_range_incomplete fileID=\(fileID) offset=\(offset) length=\(limit) retryFullDownload=true", error: error)
                    try Task.checkCancellation()
                    let completeFile = try await client.downloadFile(
                        fileId: fileID,
                        limit: 0,
                        offset: 0,
                        priority: 32,
                        synchronous: true
                    )
                    data = try readLocalFile(completeFile, offset: offset, limit: limit)
                }
                PlaybackDiagnostics.log("telegram_range_complete fileID=\(fileID) offset=\(offset) length=\(limit) received=\(data.count)")
                await fileDownloadGate.release(fileID: fileID)
                return data
            } catch {
                let tdlibCode = (error as? TDLibKit.Error).map { String($0.code) } ?? "none"
                let tdlibMessage = (error as? TDLibKit.Error)?.message ?? "none"
                PlaybackDiagnostics.log("telegram_range_failed fileID=\(fileID) offset=\(offset) length=\(limit) priority=\(priority) retry=\(cancellationRetries) tdlibCode=\(tdlibCode) tdlibMessage=\(tdlibMessage)", error: error)
                await fileDownloadGate.release(fileID: fileID)
                guard isDownloadCancelled(error), cancellationRetries < 2 else {
                    throw readableDownloadError(error)
                }
                cancellationRetries += 1
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func readLocalFile(_ file: File, offset: Int64, limit: Int64) throws -> Data {
        PlaybackDiagnostics.log("telegram_local_file fileID=\(file.id) offset=\(offset) length=\(limit) size=\(file.size) expectedSize=\(file.expectedSize) completed=\(file.local.isDownloadingCompleted) active=\(file.local.isDownloadingActive) downloadOffset=\(file.local.downloadOffset) prefixSize=\(file.local.downloadedPrefixSize) pathEmpty=\(file.local.path.isEmpty) exists=\(!file.local.path.isEmpty && FileManager.default.fileExists(atPath: file.local.path))")
        guard !file.local.path.isEmpty,
              offset >= 0,
              limit >= 0,
              offset <= Int64(Int.max) else {
            throw ServiceError.incompleteDownload
        }
        let fileURL = URL(fileURLWithPath: file.local.path)
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            throw ServiceError.incompleteDownload
        }
        PlaybackDiagnostics.log("telegram_local_bytes fileID=\(file.id) diskSize=\(fileSize) offset=\(offset) length=\(limit)")
        let availableEnd = file.local.downloadOffset.addingReportingOverflow(file.local.downloadedPrefixSize)
        let requestedCount = limit == 0 ? Int64(fileSize) - offset : limit
        let requestedEnd = offset.addingReportingOverflow(requestedCount)
        guard file.local.downloadOffset >= 0,
              file.local.downloadedPrefixSize >= 0,
              !availableEnd.overflow,
              !requestedEnd.overflow,
              requestedCount >= 0,
              requestedCount <= Int64(Int.max),
              requestedEnd.partialValue <= Int64(fileSize),
              (file.local.isDownloadingCompleted
                  || (file.local.downloadOffset <= offset && availableEnd.partialValue >= requestedEnd.partialValue)),
              (limit != 0 || file.local.isDownloadingCompleted) else {
            throw ServiceError.incompleteDownload
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            data = try handle.read(upToCount: Int(requestedCount)) ?? Data()
            guard data.count == Int(requestedCount) else { throw ServiceError.incompleteDownload }
        }
        return data
    }

    private func resolvedFileID(for track: Track) async -> Int? {
        if let fileID = refreshedFileIDs[track.id] ?? TelegramMapping.fileID(from: track.documentID) {
            return fileID
        }
        guard let fileID = await refreshedFileID(for: track) else { return nil }
        refreshedFileIDs[track.id] = fileID
        return fileID
    }

    private func refreshedFileID(for track: Track) async -> Int? {
        guard let chatID = TelegramMapping.chatID(from: track.chatID),
              let client = try? await requireReadyClient(),
              let latest = await currentTelegramTrack(for: track, in: chatID, client: client) else { return nil }
        return TelegramMapping.fileID(from: latest.documentID)
    }

    private func currentTelegramTrack(
        for track: Track,
        in chatID: Int64,
        client: TDLibClient
    ) async -> Track? {
        if track.messageID > 0,
           let message = try? await client.getMessage(chatId: chatID, messageId: track.messageID),
           let latest = TelegramMapping.track(from: message) {
            return latest
        }

        let chat = MusicChat(
            id: String(chatID),
            peerID: chatID,
            accessHash: nil,
            kind: .channel,
            title: "",
            username: nil
        )
        guard let matches = try? await searchMusic(in: chat, query: "", limit: 100) else { return nil }
        return matches.first(where: { tracksRepresentSameFile($0, track) })
    }

    private func tracksRepresentSameFile(_ lhs: Track, _ rhs: Track) -> Bool {
        if let lhsID = lhs.remoteUniqueID, !lhsID.isEmpty,
           let rhsID = rhs.remoteUniqueID, !rhsID.isEmpty {
            return lhsID == rhsID
        }
        guard !lhs.artist.isEmpty, !rhs.artist.isEmpty,
              lhs.duration > 0, rhs.duration > 0,
              abs(lhs.duration - rhs.duration) <= 2 else { return false }
        return normalizedTrackText(lhs.displayTitle) == normalizedTrackText(rhs.displayTitle)
            && normalizedTrackText(lhs.artist) == normalizedTrackText(rhs.artist)
    }

    private func normalizedTrackText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func isFileNotFound(_ error: Swift.Error) -> Bool {
        let message = error.localizedDescription
        return message.localizedCaseInsensitiveContains("TDLib 400")
            && message.localizedCaseInsensitiveContains("File not found")
    }

    private func isDownloadCancelled(_ error: Swift.Error) -> Bool {
        guard let error = error as? TDLibKit.Error else { return false }
        return error.code == 400
            && error.message.localizedCaseInsensitiveContains("File download has failed or was canceled")
    }

    private func isIncompleteDownload(_ error: Swift.Error) -> Bool {
        guard let error = error as? ServiceError,
              case .incompleteDownload = error else { return false }
        return true
    }

    private func lyricsAttachmentMatchScore(_ fileName: String, track: Track) -> Int {
        let candidate = comparableLyricsTitle(fileName.deletingPathExtension)
        let title = comparableLyricsTitle(track.displayTitle)
        let artist = comparableLyricsTitle(track.artist)
        let fileTitle = comparableLyricsTitle(track.fileName.deletingPathExtension)
        guard !candidate.isEmpty, !title.isEmpty else { return 0 }
        if !artist.isEmpty {
            let titleArtist = title + artist
            let artistTitle = artist + title
            if candidate == titleArtist || candidate == artistTitle { return 140 }
            if candidate.contains(titleArtist) || candidate.contains(artistTitle) { return 130 }
        }
        if candidate == title { return 120 }
        if !artist.isEmpty, candidate == artist { return 118 }
        if !fileTitle.isEmpty, candidate == fileTitle { return 115 }
        if candidate.contains(title) || title.contains(candidate) { return 100 }
        if !artist.isEmpty, candidate.contains(artist) || artist.contains(candidate) { return 98 }
        if !fileTitle.isEmpty, candidate.contains(fileTitle) || fileTitle.contains(candidate) { return 95 }
        let candidateWords = Set(normalizedLyricsWords(fileName.deletingPathExtension))
        let expectedWords = Set(normalizedLyricsWords(track.displayTitle) + normalizedLyricsWords(track.artist))
        guard !candidateWords.isEmpty, !expectedWords.isEmpty else { return 0 }
        let overlap = candidateWords.intersection(expectedWords).count
        return overlap * 2 >= expectedWords.count ? 60 + overlap : 0
    }

    private func comparableLyricsTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedLyricsWords(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "_", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func decodeLyricsText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)
    }

    private func readableLoginError(_ error: Swift.Error) -> Swift.Error {
        if error is ServiceError || error is AppConfigurationError { return error }
        let message: String
        if let error = error as? TDLibKit.Error {
            guard error.code != 406 else {
                return ServiceError.telegram("Telegram could not complete the login request (error 406).")
            }
            message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = error.localizedDescription
        }
        let uppercased = message.uppercased()
        if uppercased.contains("API_ID_INVALID") { return ServiceError.invalidAPIID }
        if uppercased.contains("PHONE_NUMBER_INVALID") { return ServiceError.invalidPhoneNumber }
        if uppercased.contains("PHONE_CODE_INVALID") || uppercased.contains("EMAIL_VERIFY_CODE_INVALID") {
            return ServiceError.telegram("That Telegram verification code is incorrect.")
        }
        if uppercased.contains("PASSWORD_HASH_INVALID") { return ServiceError.telegram("That two-step verification password is incorrect.") }
        if uppercased.contains("FLOOD") || uppercased.contains("TOO MANY REQUESTS") || uppercased.contains("429") {
            return ServiceError.telegram("Telegram has temporarily limited login attempts. Wait and try again.")
        }
        if message.isEmpty { return ServiceError.telegram("Telegram could not complete the login request.") }
        return ServiceError.telegram(message)
    }

    private func readableDownloadError(_ error: Swift.Error) -> Swift.Error {
        if error is ServiceError || error is CancellationError { return error }
        if let error = error as? TDLibKit.Error {
            guard error.code != 406 else {
                return ServiceError.telegram("Telegram could not download this file (error 406).")
            }
            let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("file reference") {
                return ServiceError.expiredFileReference
            }
            guard !message.isEmpty else {
                return ServiceError.telegram("Telegram could not download this file (TDLib error \(error.code)).")
            }
            return ServiceError.telegram("Telegram could not download this file (TDLib \(error.code)): \(message)")
        }
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("file reference") {
            return ServiceError.expiredFileReference
        }
        return ServiceError.telegram("Telegram could not download this file: \(message)")
    }

    private func closeClient() async {
        connectionState = "unknown"
        videoSessions.removeAll()
        videoDownloadWindows.removeAll()
        videoPlaybackChoices.removeAll()
        guard let client else { return }
        self.client = nil
        proxyClientReady = false
        _ = try? await client.close()
    }

    private func storageURL(for id: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Telisten/TDLib", isDirectory: true)
        let safeID = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return root.appendingPathComponent(String(safeID), isDirectory: true)
    }

    private func removeTDLibStorage(for id: String) {
        try? FileManager.default.removeItem(at: storageURL(for: id))
        // Local file IDs can be reused after deleting the TDLib database.
        UserDefaults.standard.removeObject(forKey: "video.bufferedFiles.\(id)")
    }

    private var authorizationDefaultsKey: String {
        "tdlib.authorized.\(accountID)"
    }

    private func existingPlaylistFolderID(named name: String, client: TDLibClient) async throws -> Int? {
        let key = playlistFolderKey(name)
        let cachedID = UserDefaults.standard.object(forKey: key) as? Int
        let state = try await client.getCurrentState()
        for update in state.updates {
            if case let .updateChatFolders(value) = update {
                // Discover folders created by other clients and reject stale or renamed cached IDs.
                let matches = value.chatFolders.filter { $0.name.text.text == name }
                let folderID = matches.first(where: { $0.id == cachedID })?.id ?? matches.first?.id
                if let folderID {
                    UserDefaults.standard.set(folderID, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                return folderID
            }
        }
        // An unavailable folder list must not be treated as permission to create a duplicate.
        throw ServiceError.playlistFolderFailed
    }

    private func playlistFolderKey(_ name: String) -> String {
        "tdlib.playlist.folder.\(accountID).\(name)"
    }
}
