@preconcurrency import AVFoundation
import Foundation

private actor VideoReadProbe {
    var started = false
    var cancelled = false
    func begin() { started = true }
    func cancel() { cancelled = true }
}

@main
enum VideoTests {
    static func item(_ id: Int64, caption: String = "#沧元图 第103集", duration: Double = 1301,
                     width: Int = 1920, height: Int = 1080, size: Int64 = 672_000_000) -> VideoItem {
        VideoItem(chatID: id == 1 ? -100 : -200, messageID: id, fileID: Int(id),
                  fileName: "episode.mp4", mimeType: "video/mp4", caption: caption,
                  duration: duration, size: size, width: width, height: height,
                  thumbnail: nil, hasComments: true)
    }

    static func log(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }

    static func main() async throws {
        let logMarker = "diagnostic_export_test_\(UUID().uuidString)"
        PlaybackDiagnostics.log(logMarker)
        let exportedLogs = try await PlaybackDiagnostics.exportLogs()
        defer { try? FileManager.default.removeItem(at: exportedLogs) }
        let report = try String(contentsOf: exportedLogs, encoding: .utf8)
        // Export must flush events already queued by the caller.
        precondition(report.contains(logMarker))
        precondition(report.contains("Telisten diagnostics\nApp:") && report.contains("\nSystem:"))
        precondition(report.contains("--- playback.log ---"))
        let secondExport = try await PlaybackDiagnostics.exportLogs()
        defer { try? FileManager.default.removeItem(at: secondExport) }
        precondition(secondExport != exportedLogs, "Share snapshots must not overwrite one another")
        log("PASS: diagnostic snapshot includes queued events, version header and unique export files")

        let immediate = try await VideoListRequest<Int>.run { completion in
            completion(.success(42))
            completion(.success(99))
        }
        precondition(immediate == 42, "Only the first callback may resume a request")
        let timeoutStarted = Date()
        do {
            _ = try await VideoListRequest<Int>.run(timeout: .milliseconds(20)) { _ in }
            preconditionFailure("A missing TDLib callback must time out")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        precondition(Date().timeIntervalSince(timeoutStarted) < 1)
        do {
            _ = try await VideoListRequest<Int>.run(timeout: .milliseconds(20)) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                    completion(.success(1))
                }
            }
            preconditionFailure("Late result must not bypass timeout")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        // Let the late callback run: a second continuation resume would crash.
        try await Task.sleep(for: .milliseconds(150))
        let requestProbe = VideoReadProbe()
        let pendingRequest = Task {
            try await VideoListRequest<Int>.run { _ in
                Task { await requestProbe.begin() }
            }
        }
        while !(await requestProbe.started) { try await Task.sleep(for: .milliseconds(5)) }
        let cancellationStarted = Date()
        pendingRequest.cancel()
        do { _ = try await pendingRequest.value; preconditionFailure("Cancelled request returned a value") }
        catch is CancellationError { }
        precondition(Date().timeIntervalSince(cancellationStarted) < 1)
        let cancelledBeforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoListRequest<Int>.run { _ in
                preconditionFailure("An already cancelled request must not send a query")
            }
        }
        do { _ = try await cancelledBeforeStart.value; preconditionFailure("Cancelled request returned a value") }
        catch is CancellationError { }
        let failedRequest = URLError(.notConnectedToInternet)
        do {
            _ = try await VideoListRequest<Int>.run { $0(.failure(failedRequest)) }
            preconditionFailure("TDLib error must reach the caller")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        log("PASS: callback success/error, missing callback timeout, late/duplicate callbacks and immediate cancellation")

        let original = item(1, caption: "#沧元图 #4K 第103集 评论区1080P", width: 3840, height: 2160)
        let correct = item(2)
        precondition(!original.is1080p, "A 4K caption mentioning 1080P must not count as 1080P")
        precondition(correct.is1080p)
        precondition(item(3, width: 1080, height: 1920).is1080p)
        precondition(!item(3, width: 1280, height: 720).is1080p)
        precondition(item(3, caption: "第 103 集 1080p", width: 0, height: 0).is1080p)
        precondition(!item(3, caption: "第103集 21080p", width: 0, height: 0).is1080p)
        precondition(!item(3, caption: "#4K 第103集 评论区1080P", width: 0, height: 0).is1080p)
        var genericDocument = correct
        genericDocument.mimeType = "application/octet-stream"
        precondition(genericDocument.streamingMimeType == "video/mp4")
        genericDocument.fileName = "episode.MOV"
        precondition(genericDocument.streamingMimeType == "video/quicktime")
        let wrongEpisode = item(3, caption: "#沧元图 第104集 1080P")
        let advert = item(4, caption: "1080P", duration: 15)
        precondition(VideoItem.preferred1080p(in: [original, wrongEpisode, advert, correct], for: original)?.id == correct.id)
        precondition(VideoItem.preferred1080p(in: [wrongEpisode, advert], for: original) == nil)
        let document = item(5, caption: "#沧元图 第103集 1080P", duration: 0, width: 0, height: 0)
        precondition(VideoItem.preferred1080p(in: [document], for: original)?.id == document.id)
        precondition(VideoItem.preferred1080p(in: [item(5, caption: "1080P", duration: 0, width: 0, height: 0)], for: original) == nil)
        precondition(item(6, caption: "Series S02E003 1080P").episode == "3")
        precondition(item(6, caption: "Series EP.003 1080P").episode == "3")
        let fakeLabel = item(6, caption: "第103集 1080P", width: 0, height: 0)
        precondition(VideoItem.preferred1080p(in: [fakeLabel, correct], for: original)?.id == correct.id)
        precondition(VideoItem.preferred1080p(in: [], for: original) == nil)

        // A channel's comment count may be absent. Always anchor reply queries
        // at the original channel post, even as cursors use discussion IDs.
        var uncounted = original
        uncounted.hasComments = false
        var lookup = VideoCommentLookup(original: uncounted)
        precondition(lookup.canLoadMore)
        var forwardedRoot = correct
        forwardedRoot.fileID = original.fileID
        precondition(lookup.consume(VideoPage(items: [forwardedRoot], nextOffset: 500)) == nil)
        precondition(lookup.chatID == original.chatID && lookup.messageID == original.messageID)
        precondition(lookup.offset == 500 && lookup.canLoadMore)
        precondition(lookup.consume(VideoPage(items: [], nextOffset: 400)) == nil)
        precondition(lookup.canLoadMore && lookup.offset == 400)
        let matchedReply = lookup.consume(VideoPage(items: [correct], nextOffset: 300))
        precondition(matchedReply?.chatID == correct.chatID && matchedReply?.size == 672_000_000)
        precondition(lookup.chatID == original.chatID && lookup.messageID == original.messageID)
        var repeated = VideoCommentLookup(original: original)
        _ = repeated.consume(VideoPage(items: [], nextOffset: 500))
        _ = repeated.consume(VideoPage(items: [], nextOffset: 500))
        precondition(!repeated.canLoadMore)
        var limited = VideoCommentLookup(original: original)
        for page in 0..<10 { _ = limited.consume(VideoPage(items: [], nextOffset: Int64(1000 - page))) }
        precondition(!limited.canLoadMore)
        log("PASS: channel comment anchor, absent comment count, forwarded root exclusion, text-only pages, reply size and pagination bounds")

        let window = VideoBufferWindow(offset: 3_000_000_001, fileSize: 4_000_000_000)
        precondition(window.length == 32 * 1_024 * 1_024)
        precondition(window.offset % (1_024 * 1_024) == 0)
        precondition(window.contains(offset: 3_000_000_001, length: 524_288))
        precondition(!window.contains(offset: window.offset - 1, length: 1))
        precondition(!window.contains(offset: window.offset + window.length, length: 1))
        let tail = VideoBufferWindow(offset: 3_999_999_999, fileSize: 4_000_000_000)
        precondition(tail.offset + tail.length == 4_000_000_000)
        precondition(tail.contains(offset: 3_999_999_999, length: 1))
        var stalled = VideoDownloadProgress(now: 100)
        precondition(!stalled.timedOut(available: 0, now: 114))
        precondition(stalled.timedOut(available: 0, now: 115))
        var advancing = VideoDownloadProgress(now: 100)
        precondition(!advancing.timedOut(available: 100, now: 114))
        precondition(!advancing.timedOut(available: 100, now: 128))
        precondition(advancing.timedOut(available: 100, now: 129))
        var deadline = VideoDownloadProgress(now: 100)
        for step in 1...5 { precondition(!deadline.timedOut(available: Int64(step), now: Double(100 + step * 10))) }
        precondition(deadline.timedOut(available: 6, now: 160))
        log("PASS: bounded 32 MB read-ahead, 4 GB offsets, tail clipping, stalled-download timeout and total deadline")

        // A ready two-byte header must not wait for a speculative 512 KB
        // audio-prefetch block elsewhere in the file.
        let exactRead = StreamingAudioResource(fileSize: 8 * 1_024 * 1_024, mimeType: "video/mp4") { offset, length in
            precondition(offset == 4_000_000 && length == 2)
            return Data([1, 2])
        }
        let exactBytes = try await exactRead.bytes(at: 4_000_000, length: 2)
        precondition(exactBytes == Data([1, 2]))
        let probe = VideoReadProbe()
        let cancellable = StreamingAudioResource(fileSize: 8 * 1_024 * 1_024, mimeType: "video/mp4") { offset, length in
            if offset == 0 {
                await probe.begin()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { await probe.cancel(); throw error }
            }
            return Data(repeating: 0, count: Int(length))
        }
        let oldRead = Task { try await cancellable.bytes(at: 0, length: 64) }
        for _ in 0..<200 {
            if await probe.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await probe.started
        precondition(started)
        oldRead.cancel()
        do { _ = try await oldRead.value; preconditionFailure("Cancelled read returned bytes") }
        catch is CancellationError { }
        let cancelled = await probe.cancelled
        precondition(cancelled, "Cancellation must reach the byte provider")
        let soughtBytes = try await cancellable.bytes(at: 4_000_000, length: 64)
        precondition(soughtBytes.count == 64)
        log("PASS: exact video ranges, cancelled read reaches provider, and seek after cancellation")

        // Generate a real H.264 MP4 using only system frameworks, then decode a
        // frame through the same custom range resource loader used by videos.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telisten-video-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        log("Generating MP4 fixture")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            log("Writing frame \(frame)")
            let deadline = Date().addingTimeInterval(20)
            while !input.isReadyForMoreMediaData {
                precondition(Date() < deadline && writer.status == .writing, "Video encoder did not become ready")
                try await Task.sleep(for: .milliseconds(10))
            }
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 127, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        log("Finishing MP4")
        await writer.finishWriting()
        precondition(writer.status == .completed, "Could not generate MP4 fixture")
        let data = try Data(contentsOf: url)
        let resource = StreamingAudioResource(fileSize: Int64(data.count), mimeType: "video/mp4") { offset, length in
            precondition(offset >= 0 && length > 0)
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))
        }
        defer { resource.cancelAll() }
        let asset = AVURLAsset(url: URL(string: "telisten-video://test/clip.mp4")!)
        asset.resourceLoader.setDelegate(resource, queue: DispatchQueue(label: "video-test-loader"))
        log("Loading streamed MP4 metadata")
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        precondition(playable && abs(duration.seconds - 1) < 0.1)
        log("Decoding streamed MP4 frame")
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        precondition(image.image.width == 320 && image.image.height == 180)
        print("PASS: 1080P matching, wrong episode/ad rejection, document fallback, and real MP4 byte-range decoding")
    }
}
