import AVFoundation
import Foundation

@main
@MainActor
enum PlaybackRegressionTests {
    static func main() async throws {
        precondition(DisplayFormat.duration(.infinity) == "0:00")
        precondition(DisplayFormat.duration(.nan) == "0:00")
        precondition(DisplayFormat.duration(Double.greatestFiniteMagnitude) == "0:00")
        precondition(DisplayFormat.duration(271) == "4:31")

        let engine = AVPlayer()
        let player = AudioPlayer(player: engine, configureSystemPlayback: false)
        var completions = 0
        player.onFinished = { completions += 1 }
        let first = track(id: 1)
        let second = track(id: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        buffer.floatChannelData![0].initialize(repeating: 0, count: 44_100)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        player.beginLoading(first)
        player.load(first, from: url, autoplay: false)
        let oldItem = engine.currentItem!
        // Delivery schedules a main-actor task. Switch tracks before it runs.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        player.beginLoading(second)
        player.load(second, from: url, autoplay: false)
        for _ in 0..<10 { await Task.yield() }
        precondition(player.track?.id == second.id)
        precondition(completions == 0, "A retired item must not advance the replacement track")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: engine.currentItem!)
        for _ in 0..<10 { await Task.yield() }
        precondition(completions == 1, "The active item must still advance on completion")

        player.beginLoading(track(id: 3, duration: .nan))
        precondition(player.duration == 0)
        player.seek(to: .nan)
        player.seek(to: .infinity)
        precondition(player.currentTime.isFinite)

        // A cold-cache stream can finish caching while paused or after decoding
        // fails. Only a stream that still wants playback should switch to disk.
        let bytes = try Data(contentsOf: url)
        player.beginLoading(first)
        player.loadStreaming(first) { offset, length in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + Int(length)))
        }
        precondition(player.canRecoverFromCachedFile(first))
        player.pause()
        player.useCachedFileIfNeeded(first, from: url)
        precondition(!player.isPlaying && !player.canRecoverFromCachedFile(first),
                     "Completing the cache must not resume a paused stream")
        player.play()
        player.failLoading()
        precondition(player.canRecoverFromCachedFile(first))
        player.useCachedFileIfNeeded(first, from: url)
        precondition(player.hasCurrentItem && !player.canRecoverFromCachedFile(first),
                     "A failed stream must be able to fall back to the downloaded file")
        player.reset()

        let waitingEngine = PlaybackTestEngine()
        let waitingPlayer = AudioPlayer(player: waitingEngine, configureSystemPlayback: false)
        waitingPlayer.beginLoading(first)
        waitingPlayer.load(first, from: url)
        waitingPlayer.play()
        precondition(!waitingPlayer.isPlaying && waitingPlayer.isLoading,
                     "Requesting playback must keep a waiting player in the loading state")
        for _ in 0..<500 {
            if waitingEngine.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(waitingEngine.currentItem?.status == .readyToPlay)
        for _ in 0..<10 { await Task.yield() }
        precondition(!waitingPlayer.isPlaying && waitingPlayer.isLoading,
                     "A ready item must not report playback while the engine is still waiting")
        waitingEngine.setPlaybackStatus(.playing)
        for _ in 0..<10 { await Task.yield() }
        precondition(waitingPlayer.isPlaying && !waitingPlayer.isLoading)
        waitingEngine.setPlaybackStatus(.waitingToPlayAtSpecifiedRate)
        for _ in 0..<10 { await Task.yield() }
        precondition(!waitingPlayer.isPlaying && waitingPlayer.isLoading,
                     "Rebuffering must clear the playing state and show loading")
        waitingEngine.setPlaybackStatus(.paused)
        waitingPlayer.failLoading()
        for _ in 0..<10 { await Task.yield() }
        precondition(!waitingPlayer.isPlaying && !waitingPlayer.isLoading,
                     "A queued paused notification must not restart the loading indicator after failure")
        waitingEngine.setPlaybackStatus(.waitingToPlayAtSpecifiedRate)
        waitingPlayer.toggle()
        precondition(waitingPlayer.isLoading,
                     "Toggling after a loading failure must retry playback")
        waitingPlayer.toggle()
        precondition(!waitingPlayer.isPlaying && !waitingPlayer.isLoading,
                     "Toggling while waiting must pause the pending playback request")

        waitingPlayer.beginLoading(first)
        waitingPlayer.loadStreaming(first) { offset, length in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + Int(length)))
        }
        let streamingItem = waitingEngine.currentItem
        waitingPlayer.useCachedFileIfNeeded(second, from: url)
        precondition(waitingEngine.currentItem === streamingItem,
                     "A different track finishing its download must not replace the current stream")
        waitingPlayer.useCachedFileIfNeeded(first, from: url)
        precondition((waitingEngine.currentItem?.asset as? AVURLAsset)?.url == url,
                     "A waiting stream must switch to the completed local file immediately")
        precondition(!waitingPlayer.isPlaying && waitingPlayer.isLoading)
        waitingPlayer.reset()

        // A slow cold-cache stream must not attach an unprepared AVPlayerItem
        // on the main actor, or prevent pause/local recovery while waiting.
        let flacURL = URL(fileURLWithPath: "Tests/Fixtures/EmbeddedLyrics/timed.flac")
        let flacBytes = try Data(contentsOf: flacURL)
        var preparationErrors: [String] = []
        player.onError = { preparationErrors.append($0) }
        var flac = track(id: 4)
        flac.fileName = "timed.flac"
        flac.mimeType = "audio/x-flac"
        flac.size = Int64(flacBytes.count)
        let downloadedFlacURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-playback-\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: downloadedFlacURL) }
        try flacBytes.write(to: downloadedFlacURL)
        player.beginLoading(flac)
        player.load(flac, from: downloadedFlacURL, autoplay: false)
        player.reset()
        try FileManager.default.removeItem(at: downloadedFlacURL)
        let delayed = DelayedPlaybackBytes(flacBytes)
        player.beginLoading(flac)
        player.loadStreaming(flac) { offset, length in
            try await delayed.read(offset: offset, length: length)
        }
        for _ in 0..<200 {
            if await delayed.wasRequested { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didRequest = await delayed.wasRequested
        precondition(didRequest && player.isLoading && !player.hasCurrentItem,
                     "Slow stream preparation must yield the main actor before attaching a player item")
        player.pause()
        await delayed.release()
        for _ in 0..<500 {
            if player.hasCurrentItem { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(player.hasCurrentItem && !player.isPlaying && !player.isLoading,
                     "Finishing stream preparation must respect a pause made while waiting: item=\(player.hasCurrentItem), playing=\(player.isPlaying), loading=\(player.isLoading), errors=\(preparationErrors)")

        let delayedRecovery = DelayedPlaybackBytes(flacBytes)
        player.beginLoading(flac)
        player.loadStreaming(flac) { offset, length in
            try await delayedRecovery.read(offset: offset, length: length)
        }
        for _ in 0..<200 {
            if await delayedRecovery.wasRequested { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var reloadRequests = 0
        player.onPlayRequested = { reloadRequests += 1 }
        player.pause()
        player.play()
        precondition(player.isLoading && reloadRequests == 0,
                     "Resuming a preparing stream must reuse it instead of starting another download")
        try flacBytes.write(to: downloadedFlacURL)
        player.useCachedFileIfNeeded(flac, from: downloadedFlacURL)
        let recoveredItem = engine.currentItem
        precondition((recoveredItem?.asset as? AVURLAsset)?.url == downloadedFlacURL,
                     "A completed download must bypass pending remote metadata preparation")
        await delayedRecovery.release()
        try await Task.sleep(for: .milliseconds(100))
        precondition(engine.currentItem === recoveredItem,
                     "A cancelled stream preparation must not replace the recovered local item")
        player.reset()
        print("PASS: retired-item completion race, active-item completion, non-finite duration/seek, oversized duration formatting, paused cache completion, failed stream recovery, waiting/ready/playing/rebuffering states, toggle while waiting, immediate local fallback, unrelated download completion")
        print("PASS: deleted-file replay, slow FLAC preparation yields the main actor, pause/resume during preparation, cached recovery cancels pending preparation")
    }

    static func track(id: Int64, duration: TimeInterval = 1) -> Track {
        Track(documentID: id, accessHash: 0, fileReference: Data(), dcID: 1,
              messageID: id, chatID: "test", title: "Fixture", artist: "", fileName: "test.wav",
              mimeType: "audio/wav", duration: duration, size: 88_244, date: Date())
    }
}

actor DelayedPlaybackBytes {
    private let bytes: Data
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasRequested = false

    init(_ bytes: Data) { self.bytes = bytes }

    func read(offset: Int64, length: Int32) async throws -> Data {
        wasRequested = true
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        try Task.checkCancellation()
        return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + Int(length)))
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class PlaybackTestEngine: AVPlayer, @unchecked Sendable {
    private nonisolated(unsafe) var playbackStatus: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate

    override var timeControlStatus: AVPlayer.TimeControlStatus { playbackStatus }

    override func play() {}

    func setPlaybackStatus(_ status: AVPlayer.TimeControlStatus) {
        willChangeValue(forKey: "timeControlStatus")
        playbackStatus = status
        didChangeValue(forKey: "timeControlStatus")
    }
}
