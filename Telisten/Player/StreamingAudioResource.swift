@preconcurrency import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

enum PlaybackDiagnostics {
    private static let logger = Logger(subsystem: "com.telisten.player", category: "Playback")
    private static let queue = DispatchQueue(label: "Telisten.PlaybackDiagnostics")

    static func log(_ event: String, error: Error? = nil) {
        let message = error.map { "\(event) \(describe($0))" } ?? event
        if error != nil {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        queue.async {
            guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
            let directory = library.appending(path: "Logs/Telisten", directoryHint: .isDirectory)
            let url = directory.appending(path: "playback.log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size >= 2 * 1_024 * 1_024 {
                    let previous = directory.appending(path: "playback.previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: url, to: previous)
                }
                let timestamp = ISO8601DateFormatter().string(from: .now)
                let line = message.replacingOccurrences(of: "\n", with: " ")
                let data = Data("\(timestamp) \(line)\n".utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                logger.error("Could not write playback diagnostics: \(describe(error), privacy: .public)")
            }
        }
    }

    static func exportLogs() async throws -> URL {
        // Snapshot on the writer queue so pending events are included and a
        // concurrent rotation cannot split the exported files.
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let library = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                    let directory = library.appendingPathComponent("Logs/Telisten", isDirectory: true)
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
                    var report = "Telisten diagnostics\nApp: \(version) (\(build))\nSystem: \(ProcessInfo.processInfo.operatingSystemVersionString)\nExported: \(ISO8601DateFormatter().string(from: .now))\n"
                    var foundLogs = false
                    for name in ["playback.previous.log", "playback.log"] {
                        let source = directory.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: source.path) else { continue }
                        report += "\n--- \(name) ---\n" + (try String(contentsOf: source, encoding: .utf8))
                        foundLogs = true
                    }
                    if !foundLogs { report += "\nNo diagnostic events have been recorded.\n" }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Telisten-diagnostics-\(UUID().uuidString).txt")
                    try report.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func describe(_ error: Error, depth: Int = 0) -> String {
        let value = error as NSError
        var result = "domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription)"
        guard depth < 4 else { return result }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " underlying={\(describe(underlying, depth: depth + 1))}"
        }
        if let underlying = value.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
            for error in underlying.prefix(4) {
                result += " underlying={\(describe(error, depth: depth + 1))}"
            }
        }
        return result
    }
}

typealias AudioByteProvider = @Sendable (_ offset: Int64, _ length: Int32) async throws -> Data
typealias ProgressiveAudioByteProvider = @Sendable (
    _ offset: Int64,
    _ length: Int32,
    _ priority: AudioTransferPriority
) async throws -> Data

enum AudioTransferPriority: Sendable, Equatable {
    case playback
    case background
}

private actor StreamWindow {
    private static let chunkSize: Int64 = 512 * 1_024
    private static let prefetchChunkCount = 2
    private static let maxConcurrentFetches = 4

    private let fileSize: Int64
    private let provider: AudioByteProvider
    private var chunks: [Int64: Data] = [:]
    private var chunkOrder: [Int64] = []
    private var requests: [Int64: Task<Data, Error>] = [:]

    init(fileSize: Int64, provider: @escaping AudioByteProvider) {
        self.fileSize = fileSize
        self.provider = provider
    }

    func bytes(at requestedOffset: Int64, length requestedLength: Int) async throws -> Data {
        guard requestedOffset >= 0, requestedOffset < fileSize, requestedLength > 0 else {
            return Data()
        }

        let length = Int(min(Int64(requestedLength), fileSize - requestedOffset))
        let firstChunk = requestedOffset - (requestedOffset % Self.chunkSize)
        let lastByte = requestedOffset + Int64(length) - 1
        let lastChunk = lastByte - (lastByte % Self.chunkSize)
        let requiredChunkCount = Int((lastChunk - firstChunk) / Self.chunkSize) + 1
        let fetchCount = max(requiredChunkCount, Self.prefetchChunkCount)

        var offsets: [Int64] = []
        offsets.reserveCapacity(fetchCount)
        for index in 0..<fetchCount {
            let offset = firstChunk + Int64(index) * Self.chunkSize
            guard offset < fileSize else { break }
            offsets.append(offset)
        }

        var fetched: [Int64: Data] = [:]
        var index = 0
        while index < offsets.count {
            let end = min(index + Self.maxConcurrentFetches, offsets.count)
            let batch = Array(offsets[index..<end])
            try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                for offset in batch {
                    group.addTask {
                        (offset, try await self.chunk(at: offset))
                    }
                }
                for try await (offset, data) in group {
                    fetched[offset] = data
                }
            }
            index = end
        }

        var result = Data()
        result.reserveCapacity(length)
        var offset = firstChunk
        var remaining = length
        var skip = Int(requestedOffset - firstChunk)
        while remaining > 0 {
            guard let chunk = fetched[offset] ?? chunks[offset] else {
                throw TransferError.incompleteData
            }
            guard skip < chunk.count else { throw TransferError.incompleteData }
            let count = min(remaining, chunk.count - skip)
            result.append(chunk.subdata(in: skip..<(skip + count)))
            remaining -= count
            offset += Self.chunkSize
            skip = 0
        }
        return result
    }

    private func chunk(at offset: Int64) async throws -> Data {
        if let data = chunks[offset] { return data }
        if let request = requests[offset] {
            return try await request.value
        }

        let provider = provider
        let length = Int32(min(Self.chunkSize, fileSize - offset))
        let request = Task<Data, Error> {
            try await provider(offset, length)
        }
        requests[offset] = request

        do {
            let data = try await request.value
            requests.removeValue(forKey: offset)
            guard data.count == Int(length) else { throw TransferError.incompleteData }
            chunks[offset] = data
            chunkOrder.removeAll { $0 == offset }
            chunkOrder.append(offset)
            while chunkOrder.count > Self.prefetchChunkCount * 2 {
                let evicted = chunkOrder.removeFirst()
                chunks.removeValue(forKey: evicted)
            }
            return data
        } catch {
            requests.removeValue(forKey: offset)
            throw error
        }
    }

    private enum TransferError: LocalizedError {
        case incompleteData

        var errorDescription: String? {
            "Telegram stopped sending this stream before the requested bytes arrived."
        }
    }
}

final class StreamingAudioResource: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let responseSize = 256 * 1_024

    private let fileSize: Int64
    private let contentType: String
    private let window: StreamWindow
    private let videoProvider: AudioByteProvider?
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(fileSize: Int64, mimeType: String, provider: @escaping AudioByteProvider) {
        self.fileSize = fileSize
        let normalizedMimeType = mimeType.lowercased() == "audio/x-flac" ? "audio/flac" : mimeType
        contentType = UTType(mimeType: normalizedMimeType)?.identifier ?? UTType.audio.identifier
        window = StreamWindow(fileSize: fileSize, provider: provider)
        videoProvider = normalizedMimeType.lowercased().hasPrefix("video/") ? provider : nil
    }

    func bytes(at offset: Int64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset < fileSize, length > 0 else { return Data() }
        let count = Int(min(Int64(length), fileSize - offset, Int64(Int32.max)))
        let data: Data
        if let videoProvider {
            // TDLib already preloads a finite video window. Waiting for the
            // audio window's extra block delays ready frames and leaves detached
            // prefetch work alive after AVPlayer cancels or seeks.
            data = try await videoProvider(offset, Int32(count))
            guard data.count == count else { throw URLError(.cannotDecodeContentData) }
        } else { data = try await window.bytes(at: offset, length: count) }
        try Task.checkCancellation()
        return data
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = fileSize
            information.isByteRangeAccessSupported = true
        }

        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let context = "url=\(loadingRequest.request.url?.absoluteString ?? "unknown") offset=\(request.requestedOffset) length=\(request.requestedLength) currentOffset=\(request.currentOffset) toEnd=\(request.requestsAllDataToEndOfResource) size=\(fileSize) type=\(contentType)"
        PlaybackDiagnostics.log("resource_request \(context)")
        let identifier = ObjectIdentifier(loadingRequest)
        // AVAssetResourceLoader requires us to retain asynchronous requests
        // until finishLoading or cancellation; a weak request can disappear and
        // leave AVPlayer waiting forever without another network read.
        let task = Task { [weak self] in
            guard let self else {
                if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                    loadingRequest.finishLoading(with: URLError(.cancelled))
                }
                return
            }
            do {
                var offset = request.currentOffset > 0 ? request.currentOffset : request.requestedOffset
                let available = max(0, fileSize - offset)
                var remaining = request.requestsAllDataToEndOfResource
                    ? available
                    : min(available, Int64(request.requestedLength))

                while remaining > 0 {
                    try Task.checkCancellation()
                    let length = Int(min(remaining, Int64(Self.responseSize)))
                    let bytes = try await self.bytes(at: offset, length: length)
                    try Task.checkCancellation()
                    guard !loadingRequest.isCancelled else { throw CancellationError() }
                    guard !bytes.isEmpty else { break }
                    request.respond(with: bytes)
                    offset += Int64(bytes.count)
                    remaining -= Int64(bytes.count)
                }
                PlaybackDiagnostics.log("resource_complete \(context) remaining=\(remaining)")
                if !loadingRequest.isCancelled, !loadingRequest.isFinished { loadingRequest.finishLoading() }
            } catch is CancellationError {
                PlaybackDiagnostics.log("resource_cancelled \(context)")
                if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                    loadingRequest.finishLoading(with: URLError(.cancelled))
                }
            } catch {
                PlaybackDiagnostics.log("resource_failed \(context)", error: error)
                if !loadingRequest.isCancelled, !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
            }
            removeTask(identifier)
        }
        store(task, for: identifier)
        // Completion/cancellation can race the task's registration.
        if loadingRequest.isFinished || loadingRequest.isCancelled {
            takeTask(for: identifier)?.cancel()
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        takeTask(for: ObjectIdentifier(loadingRequest))?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let current = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    private func store(_ task: Task<Void, Never>, for identifier: ObjectIdentifier) {
        lock.lock()
        tasks[identifier] = task
        lock.unlock()
    }

    private func takeTask(for identifier: ObjectIdentifier) -> Task<Void, Never>? {
        lock.lock()
        let task = tasks.removeValue(forKey: identifier)
        lock.unlock()
        return task
    }

    private func removeTask(_ identifier: ObjectIdentifier) {
        _ = takeTask(for: identifier)
    }
}
