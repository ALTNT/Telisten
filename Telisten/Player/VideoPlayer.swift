@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published var isLoading = false
    @Published var isBuffering = false
    @Published var errorMessage: String?
    @Published var choice: VideoPlaybackChoice?
    @Published var usingOriginal = false

    private let service: TelegramService
    private let accountID: String
    private var session: UUID?
    private let original: VideoItem
    private let progressKey: String
    private var resource: StreamingAudioResource?
    private let resourceQueue = DispatchQueue(label: "ad.neko.video.resource-loader")
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var hasRestoredProgress = false
    private var canSaveProgress = false
    private var wantsPlayback = false

    init(service: TelegramService, original: VideoItem, accountID: String) {
        self.service = service
        self.original = original
        self.accountID = accountID
        // Keep one progress record when switching between the post and its reply.
        progressKey = "video.progress.\(accountID).\(original.id)"
        // Apple requires false when a custom resource loader supplies media
        // bytes: AVPlayer's network predictions do not apply to this transport.
        player.automaticallyWaitsToMinimizeStalling = false
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = self.player.timeControlStatus
                let reason = self.player.reasonForWaitingToPlay?.rawValue ?? "none"
                let buffering = self.player.currentItem != nil
                    && self.player.currentItem?.status != .failed && status == .waitingToPlayAtSpecifiedRate
                if self.isBuffering != buffering { self.isBuffering = buffering }
                PlaybackDiagnostics.log("video_state status=\(status.rawValue) reason=\(reason) time=\(self.player.currentTime().seconds)")
            }
        }
    }

    func start(prefer1080p: Bool, playOriginal: Bool = false) {
        stop()
        let requestID = UUID()
        generation = requestID
        isLoading = true
        wantsPlayback = true
        errorMessage = nil
        choice = nil
        usingOriginal = playOriginal
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await service.videoPlaybackChoice(for: original, prefer1080p: prefer1080p && !playOriginal)
                try Task.checkCancellation()
                guard generation == requestID else { return }
                choice = selection
                let video = selection.selected
                guard video.size > 0 else { throw URLError(.zeroByteResource) }
                let token = try await service.beginVideoPlayback(video, expectedAccountID: accountID)
                guard !Task.isCancelled, generation == requestID else {
                    await service.endVideoPlayback(token)
                    return
                }
                session = token
                let service = service
                let resource = StreamingAudioResource(fileSize: video.size, mimeType: video.streamingMimeType) { offset, length in
                    try await service.videoBytes(video, session: token, offset: offset, length: length)
                }
                self.resource = resource
                let suffix = (video.fileName as NSString).pathExtension
                let url = URL(string: "telisten-video://file/\(video.fileID).\(suffix.isEmpty ? "mp4" : suffix)")!
                let asset = AVURLAsset(url: url)
                asset.resourceLoader.setDelegate(resource, queue: resourceQueue)
                guard try await asset.load(.isPlayable) else { throw AVError(.fileFormatNotRecognized) }
                try Task.checkCancellation()
                guard generation == requestID else { return }
                let item = AVPlayerItem(asset: asset)
                // Give network fluctuations room to recover while TDLib keeps
                // a separate finite download window ahead of the decoder.
                item.preferredForwardBufferDuration = 60
                statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    let failed = item.error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == requestID else { return }
                        if status == .failed {
                            self.isBuffering = false
                            self.errorMessage = failed ?? localizedUI("This video format is not supported on this device.")
                            self.isLoading = false
                        } else if status == .readyToPlay {
                            self.restoreProgress(requestID: requestID)
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.saveProgress() }
                }
            } catch is CancellationError { }
            catch {
                guard generation == requestID else { return }
                errorMessage = error is AVError ? error.localizedDescription : UserFacingError.message(for: error)
                isLoading = false
            }
        }
    }

    private func restoreProgress(requestID: UUID) {
        guard !hasRestoredProgress else { return }
        hasRestoredProgress = true
        let seconds = UserDefaults.standard.double(forKey: progressKey)
        let duration = player.currentItem?.duration.seconds ?? 0
        let start = seconds.isFinite && seconds > 0 && (!duration.isFinite || seconds < duration - 5) ? seconds : 0
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestID else { return }
                self.canSaveProgress = true
                self.isLoading = false
                if self.wantsPlayback { self.player.play() }
            }
        }
    }

    private func saveProgress() {
        guard canSaveProgress else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let completed = duration.isFinite && duration > 0 && seconds >= duration - 5
        UserDefaults.standard.set(completed ? 0 : seconds, forKey: progressKey)
    }

    func pause() {
        PlaybackDiagnostics.log("video_pause time=\(player.currentTime().seconds)")
        isBuffering = false
        wantsPlayback = false
        saveProgress()
        player.pause()
    }

    func stop() {
        PlaybackDiagnostics.log("video_stop time=\(player.currentTime().seconds)")
        isBuffering = false
        wantsPlayback = false
        saveProgress()
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        resource?.cancelAll()
        resource = nil
        if let session {
            let service = service
            Task { await service.endVideoPlayback(session) }
        }
        session = nil
        hasRestoredProgress = false
        canSaveProgress = false
        isLoading = false
    }
}
