import Foundation

private final class PlaylistFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    nonisolated(unsafe) static var fixture: @Sendable (URL) -> (Int, [String: String], [String: Any]) = { _ in (500, [:], [:]) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url)
        let (code, headers, body) = Self.fixture(url)
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ImportedPlaylistTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            for url in ["https://163cn.tv/blcb4v85", "https://y.qq.com/n/ryqq_v2/playlist/8715593947"] {
                let playlist = try await PlaylistImportService().preview(url)
                precondition(playlist.isComplete)
                print("LIVE: \(playlist.platform.rawValue), \(playlist.entries.count)/\(playlist.expectedCount), \(playlist.title)")
            }
            return
        }
        let shared = try PlaylistImportService.sharedURL("分享歌单：https://y.qq.com/n/ryqq_v2/playlist/8715593947，")
        precondition(PlaylistImportService.reference(shared)?.1 == "8715593947")
        precondition(PlaylistImportService.reference(URL(string: "https://music.163.com/#/playlist?id=42")!)?.1 == "42")
        precondition(PlaylistImportService.reference(URL(string: "https://music.163.com/song/42")!) == nil)
        for link in ["http://music.163.com/playlist?id=1", "https://music.163.com.evil.test/playlist?id=1",
                     "https://evil@music.163.com/playlist?id=1", "https://music.163.com:444/playlist?id=1"] {
            precondition(!PlaylistImportService.allowedURL(URL(string: link)!))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistFixtureProtocol.self]
        let service = PlaylistImportService(session: URLSession(configuration: configuration))
        PlaylistFixtureProtocol.fixture = { url in
            if url.host == "163cn.tv" {
                return (302, ["Location": "https://music.163.com/playlist?id=42"], [:])
            }
            if url.path.contains("playlist/detail") {
                return (200, [:], ["code": 200, "playlist": ["name": "Fixture", "trackCount": 3,
                    "trackIds": [["id": 3], ["id": 1], ["id": 2]], "tracks": [
                        ["id": 1, "name": "First", "ar": [["name": "Artist"]], "dt": 180000]
                    ]]])
            }
            return (200, [:], ["code": 200, "songs": [["id": 3, "name": "Third", "artists": [["name": "Singer"]], "duration": 200000]]])
        }
        var playlist = try await service.preview("https://163cn.tv/test")
        precondition(playlist.entries.map(\.songID) == ["3", "1", "2"], "Song detail order must not change playlist order")
        precondition(playlist.entries[0].duration == 200)
        precondition(playlist.entries[2].title.isEmpty, "Unavailable metadata must retain its song ID and position")
        precondition(!playlist.isComplete)
        precondition(PlaylistFixtureProtocol.requests.count == 3)

        PlaylistFixtureProtocol.requests = []
        PlaylistFixtureProtocol.fixture = { _ in (302, ["Location": "https://127.0.0.1/private"], [:]) }
        do {
            _ = try await service.preview("https://163cn.tv/unsafe")
            preconditionFailure("Unsafe redirects must be rejected")
        } catch PlaylistImportError.invalidLink {}
        precondition(PlaylistFixtureProtocol.requests.count == 1)

        PlaylistFixtureProtocol.requests = []
        PlaylistFixtureProtocol.fixture = { url in
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "song_begin" }!.value!
            let mids = offset == "0" ? ["A", "B"] : ["C"]
            return (200, [:], ["code": 0, "cdlist": [["dissname": "QQ fixture", "total_song_num": 3,
                "songlist": mids.map { ["mid": $0, "title": "Song \($0)", "singer": [["name": "Artist"]], "interval": 180] as [String: Any] }
            ]]])
        }
        let qq = try await service.preview("https://y.qq.com/n/ryqq_v2/playlist/123")
        precondition(qq.isComplete && qq.entries.map(\.songID) == ["A", "B", "C"])
        precondition(PlaylistFixtureProtocol.requests.count == 2)
        precondition(qq.entries[0].songURL.absoluteString == "https://y.qq.com/n/ryqq/songDetail/A")

        PlaylistFixtureProtocol.fixture = { _ in
            (200, [:], ["code": 0, "cdlist": [["dissname": "Truncated", "total_song_num": 4,
                "songlist": [["mid": "A", "name": "Song A"]]]]])
        }
        let truncated = try await service.preview("https://y.qq.com/n/ryqq_v2/playlist/123")
        precondition(truncated.entries.count == 1 && !truncated.isComplete, "Ignored pagination must terminate as a partial import")
        PlaylistFixtureProtocol.fixture = { _ in (200, [:], ["code": 403]) }
        do {
            _ = try await service.preview("https://music.163.com/playlist?id=42")
            preconditionFailure("Private or inaccessible playlists must fail")
        } catch PlaylistImportError.unavailable {}

        let track = Track(documentID: 1, accessHash: 0, fileReference: Data(), dcID: 2, messageID: 3, chatID: "u:1",
            title: "Third", artist: "Singer", fileName: "Third.flac", mimeType: "audio/flac", duration: 200, size: 500,
            date: Date(), upvoteCount: nil, didUpvote: nil)
        precondition(playlist.entries[0].matches(track))
        var wrong = track
        wrong.duration = 30
        precondition(!playlist.entries[0].matches(wrong), "A preview must not match the full track")
        wrong = track; wrong.artist = "Someone else"
        precondition(!playlist.entries[0].matches(wrong))
        wrong = track; wrong.title = "Third (Live)"
        precondition(!playlist.entries[0].matches(wrong))
        var matcher = ImportedMusicReplyMatcher(entry: playlist.entries[0])
        let oldReply = matcher.isRelated(messageID: 20, replyID: 8, commandIDs: [10])
        precondition(!matcher.accepts(track, isRelated: oldReply, replyID: 8),
                     "Even matching metadata must not override a reply to an older request")
        let progress = matcher.isRelated(messageID: 21, replyID: 10, commandIDs: [10])
        precondition(progress)
        let final = matcher.isRelated(messageID: 22, replyID: 21, commandIDs: [10])
        precondition(final && matcher.accepts(track, isRelated: final, replyID: 21),
                     "Audio replying to a progress message must retain the command association")
        var previewTrack = track
        previewTrack.duration = 30
        precondition(!matcher.accepts(previewTrack, isRelated: true, replyID: 10),
                     "Reply correlation must not accept a short preview")
        precondition(matcher.accepts(track, isRelated: false, replyID: nil))
        precondition(!matcher.accepts(wrong, isRelated: false, replyID: nil))
        let unavailable = "This track is currently unavailable, please try again later."
        precondition(matcher.unavailableMessage(in: "所念皆星河 (Inst.)\nAlbum: 所念皆星河 (Instrumental)\n\(unavailable)", isRelated: true) == unavailable,
                     "A negative reply containing song metadata must end the request")
        precondition(matcher.unavailableMessage(in: unavailable, isRelated: oldReply) == nil,
                     "A late failure from an older command must not fail the current song")
        precondition(matcher.unavailableMessage(in: "Downloading… You are in queue.", isRelated: true) == nil)
        precondition(matcher.unavailableMessage(in: "Song: This track is currently unavailable\nDownloading…", isRelated: true) == nil,
                     "An unavailable phrase in a song title is not a terminal error")
        precondition(matcher.unavailableMessage(in: "❌ Song not found.", isRelated: true) != nil)
        precondition(matcher.unavailableMessage(in: "歌曲不存在，请稍后重试。", isRelated: true) != nil)
        precondition(matcher.unavailableMessage(in: unavailable, isRelated: final) != nil,
                     "Failures replying to a progress message must also end the request")
        playlist.entries[0].track = track
        var refreshed = playlist
        refreshed.entries.reverse()
        for index in refreshed.entries.indices { refreshed.entries[index].track = nil }
        refreshed = refreshed.preservingSources(from: playlist)
        precondition(refreshed.entries.last?.track == track, "Updating order must preserve the song's confirmed source")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedPlaylistStore(directory: directory)
        try store.save([playlist], for: "account/one")
        try store.save([qq], for: "account/two")
        precondition(store.load(for: "account/one") == [playlist])
        precondition(store.load(for: "account/two") == [qq])
        precondition(store.load(for: "account/three").isEmpty)
        try store.save([], for: "account/one")
        precondition(store.load(for: "account/one").isEmpty && store.load(for: "account/two") == [qq])
        print("PASS: links, redirect restrictions, metadata completion, pagination, partial imports, matching, updates and account isolation")
    }
}
