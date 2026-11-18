import Foundation

enum ImportedMusicPlatform: String, Codable, Sendable {
    case netease
    case qq

    var title: String { self == .netease ? "NetEase Cloud Music" : "QQ Music" }
}

struct ImportedPlaylistEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var songID: String
    var title: String
    var artists: [String]
    var album: String
    var duration: TimeInterval
    var songURL: URL
    var track: Track? = nil

    // Unthreaded bot replies require all three metadata checks. Never take the
    // first new audio: it may belong to a timed-out or manually sent request.
    func matches(_ candidate: Track) -> Bool {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let name = normalized(title)
        let performer = normalized(candidate.artist)
        return !name.isEmpty && normalized(candidate.title) == name
            && artists.contains { !normalized($0).isEmpty && performer.contains(normalized($0)) }
            && duration > 0 && candidate.duration > 0 && abs(duration - candidate.duration) <= 5
    }
}

struct ImportedPlaylist: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var platform: ImportedMusicPlatform
    var sourceID: String
    var title: String
    var sourceURL: URL
    var expectedCount: Int
    var entries: [ImportedPlaylistEntry]
    var importedAt = Date()

    var isComplete: Bool { entries.count == expectedCount && entries.allSatisfy { !$0.title.isEmpty } }

    func preservingSources(from previous: ImportedPlaylist?) -> ImportedPlaylist {
        var result = self
        let sources = Dictionary((previous?.entries ?? []).compactMap { entry in
            entry.track.map { (entry.songID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        for index in result.entries.indices { result.entries[index].track = sources[result.entries[index].songID] }
        return result
    }
}

struct ImportedMusicReplyMatcher {
    var entry: ImportedPlaylistEntry
    private var replyIDs: Set<Int64> = []

    init(entry: ImportedPlaylistEntry) { self.entry = entry }

    mutating func isRelated(messageID: Int64, replyID: Int64?, commandIDs: Set<Int64>) -> Bool {
        let related = replyID.map { commandIDs.contains($0) || replyIDs.contains($0) } ?? false
        if related { replyIDs.insert(messageID) }
        return related
    }

    func accepts(_ track: Track, isRelated: Bool, replyID: Int64?) -> Bool {
        // An explicit reply to another request is never a metadata candidate.
        guard replyID == nil || isRelated else { return false }
        let durationMatches = entry.duration <= 0 || (track.duration > 0 && abs(entry.duration - track.duration) <= 5)
        return (isRelated && durationMatches) || entry.matches(track)
    }

    func unavailableMessage(in text: String, isRelated: Bool) -> String? {
        // Only a reply belonging to this command may finish its request. Avoid
        // treating queue/progress text or another song's failure as terminal.
        guard isRelated else { return nil }
        let prefixes = [
            "this track is currently unavailable", "this song is currently unavailable",
            "track is currently unavailable", "song is currently unavailable",
            "track not found", "song not found", "no tracks found", "no songs found",
            "this track does not exist", "this song does not exist",
            "歌曲不存在", "歌曲暂不可用", "歌曲暂时不可用", "歌曲不可用", "歌曲已下架",
            "未找到歌曲", "未找到相关歌曲", "没有找到歌曲",
            "歌曲暫不可用", "歌曲暫時不可用", "未找到相關歌曲", "沒有找到歌曲"
        ]
        return text.components(separatedBy: .newlines).first { line in
            let normalized = line.trimmingCharacters(in: .alphanumerics.inverted).lowercased()
            return prefixes.contains { normalized.hasPrefix($0) }
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ImportedMusicWaitBudget {
    private var remaining: TimeInterval = 120
    private var lastUpdated: Date
    private var isForeground: Bool
    private var maximumDeadline: Date

    init(now: Date, isForeground: Bool) {
        lastUpdated = now
        self.isForeground = isForeground
        maximumDeadline = now.addingTimeInterval(15 * 60)
    }

    mutating func setForeground(_ foreground: Bool, now: Date) {
        if isForeground { remaining -= max(0, now.timeIntervalSince(lastUpdated)) }
        if foreground && !isForeground {
            // TDLib may need a few seconds to deliver updates after suspension.
            // Even a request suspended past its ceiling gets one recovery window.
            remaining = max(remaining, 15)
            maximumDeadline = max(maximumDeadline, now.addingTimeInterval(15))
        }
        isForeground = foreground
        lastUpdated = now
    }

    mutating func hasExpired(now: Date) -> Bool {
        setForeground(isForeground, now: now)
        // Bound background polling too, even if the app is never suspended.
        return remaining <= 0 || now >= maximumDeadline
    }
}

enum ImportedMusicError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

enum PlaylistImportError: LocalizedError {
    case invalidLink
    case unavailable
    case invalidResponse
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLink: "Enter a public NetEase or QQ Music playlist link."
        case .unavailable: "The playlist could not be read. It may be private, removed, or temporarily unavailable."
        case .invalidResponse: "The music platform returned an unsupported response. Please try again later."
        case .tooLarge: "This playlist exceeds the import limit of 10,000 songs."
        }
    }
}

private final class PlaylistRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Resolve explicitly so every short-link hop is checked before contact.
        completionHandler(nil)
    }
}

struct PlaylistImportService: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration, delegate: PlaylistRedirectDelegate(), delegateQueue: nil)
    }

    static func allowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["163cn.tv", "music.163.com", "y.qq.com", "c.y.qq.com", "i.y.qq.com"].contains(host)
    }

    static func sharedURL(_ text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "，。；、）】》,.;)]>\""))
            if let url = URL(string: value), allowedURL(url) { return url }
        }
        throw PlaylistImportError.invalidLink
    }

    static func reference(_ url: URL) -> (ImportedMusicPlatform, String)? {
        guard allowedURL(url), let host = url.host else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Older NetEase shares keep both path and query inside #/playlist?id=.
        if let fragment = components?.fragment, fragment.hasPrefix("/playlist") {
            components = URLComponents(string: "https://\(host)\(fragment)")
        }
        let path = components?.path ?? ""
        let query = components?.queryItems ?? []
        func numeric(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.count <= 20,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return value
        }
        if host == "music.163.com", ["/playlist", "/m/playlist"].contains(path),
           let id = numeric(query.first(where: { $0.name == "id" })?.value) { return (.netease, id) }
        if host.hasSuffix(".qq.com") {
            let parts = path.split(separator: "/").map(String.init)
            if let index = parts.firstIndex(of: "playlist"), parts.indices.contains(index + 1),
               let id = numeric(parts[index + 1].replacingOccurrences(of: ".html", with: "")) { return (.qq, id) }
            if path.contains("taoge") || path.contains("playlist"),
               let id = numeric(query.first(where: { ["id", "disstid"].contains($0.name) })?.value) { return (.qq, id) }
        }
        return nil
    }

    func preview(_ text: String) async throws -> ImportedPlaylist {
        var url = try Self.sharedURL(text)
        for _ in 0..<6 {
            try Task.checkCancellation()
            if let (platform, id) = Self.reference(url) {
                if platform == .netease { return try await netease(id) }
                return try await qq(id)
            }
            let (_, response) = try await response(url)
            guard (300..<400).contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  Self.allowedURL(next) else { throw PlaylistImportError.invalidLink }
            url = next
        }
        throw PlaylistImportError.invalidLink
    }

    private func response(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard Self.allowedURL(url) else { throw PlaylistImportError.invalidLink }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(url.host == "music.163.com" ? "https://music.163.com/" : "https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 20 * 1_024 * 1_024 else {
            throw PlaylistImportError.invalidResponse
        }
        return (data, http)
    }

    private func json(_ base: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, http) = try await response(components.url!)
        guard http.statusCode == 200 else { throw PlaylistImportError.unavailable }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaylistImportError.invalidResponse
        }
        return result
    }

    private func netease(_ id: String) async throws -> ImportedPlaylist {
        let root = try await json("https://music.163.com/api/v6/playlist/detail", ["id": id, "n": "10000", "s": "0"])
        guard root["code"] as? Int == 200, let playlist = root["playlist"] as? [String: Any],
              let title = playlist["name"] as? String, let count = playlist["trackCount"] as? Int else {
            throw PlaylistImportError.unavailable
        }
        guard (0...10_000).contains(count) else { throw PlaylistImportError.tooLarge }
        let songs = playlist["tracks"] as? [[String: Any]] ?? []
        let ids = (playlist["trackIds"] as? [[String: Any]])?.compactMap { Self.stringID($0["id"]) }
            ?? songs.compactMap { Self.stringID($0["id"]) }
        guard ids.count <= 10_000 else { throw PlaylistImportError.tooLarge }
        var byID = Dictionary(songs.compactMap { song in Self.stringID(song["id"]).map { ($0, song) } }, uniquingKeysWith: { first, _ in first })
        let missing = ids.filter { byID[$0] == nil }
        for offset in stride(from: 0, to: missing.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(missing[offset..<min(offset + 100, missing.count)])
            let details = try await json("https://music.163.com/api/song/detail", ["ids": "[\(batch.joined(separator: ","))]"])
            guard details["code"] as? Int == 200 else { throw PlaylistImportError.unavailable }
            for song in details["songs"] as? [[String: Any]] ?? [] {
                if let key = Self.stringID(song["id"]) { byID[key] = song }
            }
        }
        let entries = ids.enumerated().map { index, songID in
            let song = byID[songID] ?? [:]
            let artists = song["ar"] as? [[String: Any]] ?? song["artists"] as? [[String: Any]] ?? []
            let album = song["al"] as? [String: Any] ?? song["album"] as? [String: Any] ?? [:]
            return ImportedPlaylistEntry(id: "\(songID):\(index)", songID: songID, title: song["name"] as? String ?? "",
                artists: artists.compactMap { $0["name"] as? String }, album: album["name"] as? String ?? "",
                duration: ((song["dt"] as? Double) ?? (song["duration"] as? Double) ?? 0) / 1000,
                songURL: URL(string: "https://music.163.com/song/\(songID)")!)
        }
        return ImportedPlaylist(id: "netease:\(id)", platform: .netease, sourceID: id, title: title,
            sourceURL: URL(string: "https://music.163.com/playlist?id=\(id)")!, expectedCount: count, entries: entries)
    }

    private func qq(_ id: String) async throws -> ImportedPlaylist {
        var entries: [ImportedPlaylistEntry] = []
        var expected = 0
        var title = ""
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let root = try await json("https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg", [
                "disstid": id, "type": "1", "utf8": "1", "format": "json", "new_format": "1",
                "onlysong": "0", "song_begin": String(entries.count), "song_num": "200"
            ])
            guard root["code"] as? Int == 0, let playlist = (root["cdlist"] as? [[String: Any]])?.first,
                  let name = playlist["dissname"] as? String,
                  let count = playlist["total_song_num"] as? Int ?? playlist["songnum"] as? Int else {
                throw PlaylistImportError.unavailable
            }
            title = name
            expected = count
            guard (0...10_000).contains(count) else { throw PlaylistImportError.tooLarge }
            let songs = playlist["songlist"] as? [[String: Any]] ?? []
            let previousCount = entries.count
            for song in songs {
                guard let mid = song["mid"] as? String ?? song["songmid"] as? String,
                      !mid.isEmpty, mid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                      seen.insert(mid).inserted else { continue }
                let album = song["album"] as? [String: Any] ?? [:]
                entries.append(ImportedPlaylistEntry(id: "\(mid):\(entries.count)", songID: mid,
                    title: song["title"] as? String ?? song["name"] as? String ?? song["songname"] as? String ?? "",
                    artists: (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                    album: album["name"] as? String ?? song["albumname"] as? String ?? "",
                    duration: song["interval"] as? Double ?? 0,
                    songURL: URL(string: "https://y.qq.com/n/ryqq/songDetail/\(mid)")!))
                guard entries.count <= 10_000 else { throw PlaylistImportError.tooLarge }
            }
            // Some upstream responses ignore pagination. Keep a visible partial
            // snapshot instead of looping forever or reporting full success.
            if entries.count == previousCount { break }
        } while entries.count < expected && entries.count < 10_000
        return ImportedPlaylist(id: "qq:\(id)", platform: .qq, sourceID: id, title: title,
            sourceURL: URL(string: "https://y.qq.com/n/ryqq_v2/playlist/\(id)")!, expectedCount: expected, entries: entries)
    }

    private static func stringID(_ value: Any?) -> String? {
        let result = (value as? NSNumber)?.stringValue ?? value as? String
        guard let result, !result.isEmpty, result.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return result
    }
}
