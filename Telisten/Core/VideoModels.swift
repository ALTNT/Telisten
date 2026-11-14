import Foundation

/// TDLib callbacks may outlive the view. Resume the caller once, even when
/// timeout, cancellation and a late server response arrive concurrently.
final class VideoListRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?

    static func run(
        timeout: Duration = .seconds(30),
        start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) throws -> Void
    ) async throws -> Value {
        let request = VideoListRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation, timeout: timeout)
                guard !Task.isCancelled else {
                    request.finish(.failure(CancellationError()))
                    return
                }
                do { try start { request.finish($0) } }
                catch { request.finish(.failure(error)) }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    private func begin(_ continuation: CheckedContinuation<Value, Error>, timeout: Duration) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
        lock.unlock()
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

struct VideoFolder: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
}

struct VideoItem: Identifiable, Hashable, Sendable {
    var id: String { "\(chatID):\(messageID)" }
    var chatID: Int64
    var messageID: Int64
    var fileID: Int
    var fileName: String
    var mimeType: String
    var caption: String
    var duration: TimeInterval
    var size: Int64
    var width: Int
    var height: Int
    var thumbnail: Data?
    var hasComments: Bool
    // Older or locally constructed items may not have a message timestamp.
    var date: Date? = nil

    var title: String {
        let line = caption.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? fileName : line
    }

    var streamingMimeType: String {
        let mime = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if mime.hasPrefix("video/") { return mime }
        // Telegram documents can carry application/octet-stream even for MP4.
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    var is1080p: Bool {
        // Real dimensions take priority: 4K posts often mention a 1080P copy.
        if width > 0, height > 0 { return (1_000...1_100).contains(min(width, height)) }
        let text = "\(fileName) \(caption)"
        if text.range(of: #"(?i)(?<![a-z0-9])(?:4k|2160p)(?![a-z0-9])"#, options: .regularExpression) != nil { return false }
        return text.range(
            of: #"(?i)(?<!\d)1080\s*[pi]?(?!\d)"#, options: .regularExpression
        ) != nil
    }

    var episode: String? {
        let text = "\(caption) \(fileName)"
        let patterns = [#"第\s*(\d+)\s*[集话話]"#, #"(?i)\b(?:ep(?:isode)?[ ._-]*|s\d+e)(\d+)\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return Int(text[range]).map(String.init)
        }
        return nil
    }

    static func preferred1080p(in replies: [VideoItem], for original: VideoItem) -> VideoItem? {
        replies.filter { candidate in
            guard candidate.id != original.id, candidate.is1080p else { return false }
            if let lhs = original.episode, let rhs = candidate.episode, lhs != rhs { return false }
            if original.duration > 0, candidate.duration > 0 {
                return abs(original.duration - candidate.duration) <= max(10, original.duration * 0.02)
            }
            // Documents may have no duration; require an explicit matching episode.
            return original.episode != nil && original.episode == candidate.episode
        }.sorted {
            let lhsKnown = $0.width > 0 && $0.height > 0
            let rhsKnown = $1.width > 0 && $1.height > 0
            if lhsKnown != rhsKnown { return lhsKnown }
            if $0.size != $1.size { return $0.size < $1.size }
            return $0.messageID > $1.messageID
        }.first
    }
}

struct VideoPage: Sendable {
    var items: [VideoItem]
    var nextOffset: Int64?
}

/// Keep the channel post as the lookup anchor while paging through replies
/// whose message IDs belong to a different chat.
struct VideoCommentLookup {
    let original: VideoItem
    private(set) var offset: Int64 = 0
    private(set) var canLoadMore = true
    private var pageCount = 0
    private var replies: [VideoItem] = []

    init(original: VideoItem) { self.original = original }

    var chatID: Int64 { original.chatID }
    var messageID: Int64 { original.messageID }

    mutating func consume(_ page: VideoPage) -> VideoItem? {
        replies.append(contentsOf: page.items.filter { $0.fileID != original.fileID })
        pageCount += 1
        // Empty video results can still contain text comments. The cursor must
        // come from all raw messages, otherwise older video replies are missed.
        if let next = page.nextOffset, next > 0, (offset == 0 || next < offset), pageCount < 10 {
            offset = next
        } else { canLoadMore = false }
        return VideoItem.preferred1080p(in: replies, for: original)
    }
}

struct VideoPlaybackChoice: Sendable {
    var original: VideoItem
    var selected: VideoItem
    var commentsUnavailable: Bool = false
}

/// A finite forward window lets TDLib keep downloading between AVPlayer reads
/// without turning a short viewing session into a whole-file download.
struct VideoBufferWindow {
    static let capacity: Int64 = 32 * 1_024 * 1_024
    let offset: Int64
    let length: Int64

    init(offset: Int64, fileSize: Int64) {
        self.offset = max(0, offset - offset % (1_024 * 1_024))
        length = min(Self.capacity, max(0, fileSize - self.offset))
    }

    func contains(offset: Int64, length: Int64) -> Bool {
        offset >= self.offset && length >= 0 && offset <= self.offset + self.length
            && length <= self.offset + self.length - offset
    }
}

struct VideoDownloadProgress {
    private let started: TimeInterval
    private var lastProgress: TimeInterval
    private var available: Int64 = 0

    init(now: TimeInterval) {
        started = now
        lastProgress = now
    }

    mutating func timedOut(available: Int64, now: TimeInterval) -> Bool {
        if available > self.available {
            self.available = available
            lastProgress = now
        }
        // A stalled transfer must release the per-file gate so later seeks and
        // retries cannot remain queued behind an unfinished synchronous call.
        return now - lastProgress >= 15 || now - started >= 60
    }
}
