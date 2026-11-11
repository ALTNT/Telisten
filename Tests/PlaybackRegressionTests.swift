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
        print("PASS: retired-item completion race, active-item completion, non-finite duration/seek, oversized duration formatting, paused cache completion, failed stream recovery")
    }

    static func track(id: Int64, duration: TimeInterval = 1) -> Track {
        Track(documentID: id, accessHash: 0, fileReference: Data(), dcID: 1,
              messageID: id, chatID: "test", title: "Fixture", artist: "", fileName: "test.wav",
              mimeType: "audio/wav", duration: duration, size: 88_244, date: Date())
    }
}
