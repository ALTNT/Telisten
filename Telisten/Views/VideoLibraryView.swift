import AVKit
import Combine
import SwiftUI

@MainActor
final class VideoLibraryModel: ObservableObject {
    @Published var folders: [VideoFolder] = []
    @Published var chats: [MusicChat] = []
    @Published var folderID = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    let service: TelegramService
    let accountID: String
    private var generation = UUID()
    private var folderKey: String { "video.folder.\(accountID)" }

    init(service: TelegramService, accountID: String) {
        self.service = service
        self.accountID = accountID
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            folders = try await service.videoFolders()
            try Task.checkCancellation()
            let saved = UserDefaults.standard.object(forKey: folderKey) as? Int
            if let saved, saved == 0 || folders.contains(where: { $0.id == saved }) { folderID = saved }
            else { folderID = folders.first(where: { $0.title.contains("影视") || $0.title.contains("影視") })?.id ?? 0 }
            await selectFolder(folderID)
        } catch is CancellationError { isLoading = false }
        catch { errorMessage = UserFacingError.message(for: error); isLoading = false }
    }

    func selectFolder(_ id: Int) async {
        let requestID = UUID()
        generation = requestID
        folderID = id
        chats = []
        errorMessage = nil
        isLoading = true
        UserDefaults.standard.set(id, forKey: folderKey)
        do {
            let values = try await service.videoChats(folderID: id == 0 ? nil : id)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            chats = values
        } catch is CancellationError { }
        catch { if generation == requestID { errorMessage = UserFacingError.message(for: error) } }
        if generation == requestID { isLoading = false }
    }
}

struct VideoLibraryView: View {
    @StateObject var library: VideoLibraryModel
    @ObservedObject var musicPlayer: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Telegram folder", selection: Binding(
                    get: { library.folderID },
                    set: { id in Task { await library.selectFolder(id) } }
                )) {
                    Text("All chats").tag(0)
                    ForEach(library.folders) { folder in Text(folder.title).tag(folder.id) }
                }
                .padding()
                if library.isLoading { ProgressView().padding() }
                if let error = library.errorMessage {
                    Text(error).foregroundStyle(.red).padding()
                    Button("Retry") { Task { await library.load() } }
                }
                List(library.chats) { chat in
                    NavigationLink {
                        VideoChannelView(service: library.service, accountID: library.accountID, chat: chat, musicPlayer: musicPlayer)
                    } label: {
                        Label(chat.title, systemImage: chat.symbolName)
                    }
                }
                if !library.isLoading, library.errorMessage == nil, library.chats.isEmpty {
                    Text("No chats in this folder.").foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await library.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(library.isLoading)
                        .accessibilityLabel("Refresh")
                }
            }
        }
        .task { await library.load() }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 560)
        .background { VideoLibraryWindowConfiguration() }
        #endif
    }
}

#if os(macOS)
private struct VideoLibraryWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // This browsing sheet has no pending edits, so it should allow
            // normal application termination from the Dock or Command-Q.
            window?.preventsApplicationTerminationWhenModal = false
        }
    }
}
#endif

private struct VideoChannelView: View {
    let service: TelegramService
    let accountID: String
    let chat: MusicChat
    @ObservedObject var musicPlayer: AudioPlayer
    @AppStorage("video.prefer1080p") private var prefer1080p = true
    @State private var choices: [String: VideoPlaybackChoice] = [:]
    @State private var failedLookups: Set<String> = []
    @State private var checkingVideoIDs: Set<String> = []
    @State private var commentLookupGeneration = UUID()
    @State private var items: [VideoItem] = []
    @State private var query = ""
    @State private var nextOffset: Int64?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedVideo: VideoItem?
    @State private var generation = UUID()

    var body: some View {
        List {
            ForEach(items) { video in
                let choice = prefer1080p ? choices[video.id] : nil
                let displayedVideo = choice?.selected ?? video
                Button {
                    musicPlayer.pause()
                    #if os(macOS)
                    VideoPlaybackWindow.shared.open(service: service, original: video, accountID: accountID, musicPlayer: musicPlayer)
                    #else
                    selectedVideo = video
                    #endif
                } label: {
                    HStack(spacing: 12) {
                        thumbnail(displayedVideo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayedVideo.title).lineLimit(2).foregroundStyle(.primary)
                            HStack(spacing: 0) {
                                // Use the channel post's date, even when its reply supplies the video.
                                if let date = video.date {
                                    Text(date, format: .dateTime.month().day())
                                    Text(" · ")
                                }
                                Text("\(DisplayFormat.duration(displayedVideo.duration)) · \(DisplayFormat.fileSize(displayedVideo.size))")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            videoSource(video, choice: choice)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if isLoading { ProgressView() }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load(reset: items.isEmpty) } }
            }
            if nextOffset != nil, !isLoading {
                Button("Load more") { Task { await load(reset: false) } }
            }
            if items.isEmpty, !isLoading, errorMessage == nil {
                Text("No videos found.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(chat.title)
        .searchable(text: $query)
        .task(id: query) {
            // Cancel old searches before replacing the channel's results.
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            await load(reset: true)
        }
        .task(id: commentLookupKey) {
            guard !Task.isCancelled else { return }
            let requestID = UUID()
            commentLookupGeneration = requestID
            checkingVideoIDs = []
            defer { if commentLookupGeneration == requestID { checkingVideoIDs = [] } }
            guard prefer1080p else { return }
            let pending = items.filter { !$0.is1080p && choices[$0.id] == nil && !failedLookups.contains($0.id) }
            let service = service
            // Keep four metadata lookups in flight. A slow post must not block
            // every following episode, or start requests for the whole channel.
            await withTaskGroup(of: (String, VideoPlaybackChoice?).self) { group in
                var nextIndex = min(4, pending.count)
                for video in pending.prefix(nextIndex) {
                    checkingVideoIDs.insert(video.id)
                    group.addTask {
                        do { return (video.id, try await service.videoPlaybackChoice(for: video, prefer1080p: true)) }
                        catch { return (video.id, nil) }
                    }
                }
                while let (id, choice) = await group.next() {
                    // A replaced search must not publish results into its successor.
                    guard !Task.isCancelled, commentLookupGeneration == requestID else {
                        group.cancelAll()
                        return
                    }
                    checkingVideoIDs.remove(id)
                    if let choice { choices[id] = choice }
                    else { failedLookups.insert(id) }
                    if nextIndex < pending.count {
                        let video = pending[nextIndex]
                        nextIndex += 1
                        checkingVideoIDs.insert(video.id)
                        group.addTask {
                            do { return (video.id, try await service.videoPlaybackChoice(for: video, prefer1080p: true)) }
                            catch { return (video.id, nil) }
                        }
                    }
                }
            }
        }
        .refreshable { await load(reset: true) }
        #if os(iOS)
        // Present playback directly over the library instead of stacking sheets.
        .fullScreenCover(item: $selectedVideo) { video in
            VideoPlaybackView(service: service, original: video, accountID: accountID, musicPlayer: musicPlayer)
        }
        #elseif !os(macOS)
        .sheet(item: $selectedVideo) { video in
            VideoPlaybackView(service: service, original: video, accountID: accountID, musicPlayer: musicPlayer)
        }
        #endif
    }

    private var commentLookupKey: String {
        "\(prefer1080p):" + items.map(\.id).joined(separator: ",")
    }

    @ViewBuilder private func videoSource(_ video: VideoItem, choice: VideoPlaybackChoice?) -> some View {
        Group {
            if let choice, choice.selected.id != choice.original.id {
                Text("1080P from comments").foregroundStyle(.green)
            } else if prefer1080p, !video.is1080p {
                if failedLookups.contains(video.id) || choice?.commentsUnavailable == true {
                    Text("Comments unavailable. Using channel original.").foregroundStyle(.secondary)
                } else if choice != nil {
                    Text("No matching 1080P found. Using channel original.").foregroundStyle(.secondary)
                } else if checkingVideoIDs.contains(video.id) {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Checking comments for 1080P…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Waiting to check comments for 1080P…").foregroundStyle(.secondary)
                }
            } else { Text("Channel original").foregroundStyle(.secondary) }
        }
        .font(.caption)
    }

    @ViewBuilder private func thumbnail(_ video: VideoItem) -> some View {
        Group {
            #if os(macOS)
            if let data = video.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { Image(systemName: "play.rectangle.fill").resizable().scaledToFit().padding(12) }
            #else
            if let data = video.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "play.rectangle.fill").resizable().scaledToFit().padding(12) }
            #endif
        }
        .frame(width: 100, height: 60).clipped().cornerRadius(6)
    }

    private func load(reset: Bool) async {
        if !reset, isLoading { return }
        let requestID = UUID()
        generation = requestID
        if reset {
            items = []
            choices = [:]
            failedLookups = []
            nextOffset = nil
        }
        isLoading = true
        errorMessage = nil
        PlaybackDiagnostics.log("video_channel_load_start request=\(requestID) chat=\(chat.peerID) reset=\(reset)")
        do {
            let page = try await service.videos(in: chat.peerID, offsetID: reset ? 0 : nextOffset ?? 0, query: query)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            nextOffset = page.nextOffset
            PlaybackDiagnostics.log("video_channel_load_complete request=\(requestID) count=\(items.count)")
        } catch is CancellationError {
            PlaybackDiagnostics.log("video_channel_load_cancelled request=\(requestID)")
        }
        catch {
            PlaybackDiagnostics.log("video_channel_load_failed request=\(requestID)", error: error)
            if generation == requestID { errorMessage = UserFacingError.message(for: error) }
        }
        if generation == requestID { isLoading = false }
    }
}

private struct VideoPlaybackView: View {
    @StateObject private var playback: VideoPlaybackModel
    @ObservedObject private var musicPlayer: AudioPlayer
    @AppStorage("video.prefer1080p") private var prefer1080p = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.isPresented) private var isPresented
    #endif
    @State private var started = false
    private var closeWindow: (() -> Void)?

    init(service: TelegramService, original: VideoItem, accountID: String, musicPlayer: AudioPlayer) {
        self.musicPlayer = musicPlayer
        _playback = StateObject(wrappedValue: VideoPlaybackModel(service: service, original: original, accountID: accountID))
    }

    #if os(macOS)
    init(playback: VideoPlaybackModel, musicPlayer: AudioPlayer, closeWindow: @escaping () -> Void) {
        self.musicPlayer = musicPlayer
        self.closeWindow = closeWindow
        _playback = StateObject(wrappedValue: playback)
    }
    #endif

    private func closePlayback() {
        #if os(iOS)
        // End the session on an explicit close, before dismissing the cover.
        playback.stop()
        #endif
        if let closeWindow { closeWindow() }
        else { dismiss() }
    }

    var body: some View {
        playbackContent
        .task {
            guard !started, !Task.isCancelled else { return }
            started = true
            playback.start(prefer1080p: prefer1080p)
        }
        #if os(iOS)
        .onDisappear {
            // AVKit full-screen presentation also hides this view. Keep its
            // item and resource loader alive while the playback cover is open.
            PlaybackDiagnostics.log("video_view_disappear presented=\(isPresented)")
            if !isPresented { playback.stop() }
        }
        .onChange(of: isPresented) { presented in
            // Also clean up when the cover is dismissed by its presenting view.
            if !presented { playback.stop() }
        }
        #elseif !os(macOS)
        .onDisappear { playback.stop() }
        #endif
        .onChange(of: musicPlayer.isPlaying) { playing in
            if playing { playback.pause() }
        }
        .onReceive(playback.player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
            // Pausing an already paused music player publishes another view
            // update and can repeatedly re-enter this KVO subscription.
            if status == .playing, musicPlayer.isPlaying || musicPlayer.isLoading { musicPlayer.pause() }
        }
        #if !os(macOS)
        .onChange(of: scenePhase) { phase in
            if phase != .active { playback.pause() }
        }
        #endif
    }

    @ViewBuilder private var playbackContent: some View {
        #if os(iOS)
        ZStack {
            Color.black.ignoresSafeArea()
            // One native player owns the controls in both portrait and landscape.
            IOSVideoSurfaceView(player: playback.player).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            if let error = playback.errorMessage {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Retry") { playback.start(prefer1080p: prefer1080p, playOriginal: playback.usingOriginal) }
                        .buttonStyle(.borderedProminent)
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            } else if playback.isLoading || playback.isBuffering {
                ProgressView(playback.isLoading ? "Preparing video…" : "Buffering video…")
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        // Keep the header clear of AVKit's volume and full-screen controls.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button { closePlayback() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Done")
                if let choice = playback.choice {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.selected.title).font(.subheadline).lineLimit(1)
                        if choice.selected.id != choice.original.id {
                            Text("Playing 1080P from comments").font(.caption).foregroundStyle(.secondary)
                        } else if choice.commentsUnavailable {
                            Text("Comments unavailable. Playing the original video.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("Playing the original video").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Play original video") { playback.start(prefer1080p: false, playOriginal: true) }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Play original video")
            }
            .padding(.horizontal, 8)
            .background(.black)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        #else
        NavigationStack {
            VStack(spacing: 12) {
                #if os(macOS)
                VideoSurfaceView(player: playback.player).frame(minHeight: 220)
                #else
                VideoPlayer(player: playback.player).frame(minHeight: 220)
                #endif
                if playback.isLoading { ProgressView("Preparing video…") }
                else if playback.isBuffering { ProgressView("Buffering video…") }
                if let choice = playback.choice {
                    if choice.selected.id != choice.original.id {
                        Text("Playing 1080P from comments").foregroundStyle(.secondary)
                    } else if choice.commentsUnavailable {
                        Text("Comments unavailable. Playing the original video.").foregroundStyle(.secondary)
                    } else { Text("Playing the original video").foregroundStyle(.secondary) }
                    Text(choice.selected.title).font(.callout).lineLimit(2)
                }
                if let error = playback.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { playback.start(prefer1080p: prefer1080p, playOriginal: playback.usingOriginal) }
                }
                HStack {
                    Button("Play original video") { playback.start(prefer1080p: false, playOriginal: true) }
                }
            }
            .padding()
            .navigationTitle("Video playback")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { closePlayback() } } }
        }
        .frame(minWidth: 760, minHeight: 540)
        #endif
    }
}

#if os(iOS)
private struct IOSVideoSurfaceView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif

#if os(macOS)
@MainActor
final class VideoPlaybackWindow: NSObject, NSWindowDelegate {
    static let shared = VideoPlaybackWindow()
    private var window: NSWindow?
    private var playback: VideoPlaybackModel?
    private var keyMonitor: Any?
    private var pendingSeek: TimeInterval?
    private var seekGeneration = UUID()

    func open(service: TelegramService, original: VideoItem, accountID: String, musicPlayer: AudioPlayer) {
        // One independent player keeps music/video coordination and progress
        // ownership unchanged when a different episode is selected.
        close()
        let playback = VideoPlaybackModel(service: service, original: original, accountID: accountID)
        let content = VideoPlaybackView(playback: playback, musicPlayer: musicPlayer) { [weak self] in
            self?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = original.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.contentViewController = NSHostingController(rootView: content)
        window.delegate = self
        window.setFrameAutosaveName("TelistenVideoPlayback")
        if !window.setFrameUsingName("TelistenVideoPlayback") { window.center() }
        self.playback = playback
        self.window = window
        // A sheet would keep the player attached to the library. A regular
        // top-level window can move and resize independently of that sheet.
        window.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers local event monitors on the main thread, before
            // focused controls and application menu shortcuts handle the key.
            // Return only a Sendable flag from assumeIsolated; NSEvent stays
            // in the synchronous event monitor callback.
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyEvent(event) == nil
            }
            return handled ? nil : event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let playback, let eventWindow = event.window else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty, !(eventWindow.firstResponder is NSTextView) else { return event }
        // AVKit may move its surface into a separate full-screen window. Only
        // handle that window if it contains this specific player's surface.
        guard eventWindow === window || containsPlayer(in: eventWindow.contentView, player: playback.player) else { return event }
        switch event.keyCode {
        case 123: seek(by: -10, player: playback.player)
        case 124: seek(by: 10, player: playback.player)
        case 49:
            if !event.isARepeat {
                if playback.player.timeControlStatus == .paused { playback.player.play() }
                else { playback.pause() }
            }
        default: return event
        }
        return nil
    }

    private func containsPlayer(in view: NSView?, player: AVPlayer) -> Bool {
        guard let view else { return false }
        if let surface = view as? AVPlayerView, surface.player === player { return true }
        return view.subviews.contains { containsPlayer(in: $0, player: player) }
    }

    private func seek(by seconds: TimeInterval, player: AVPlayer) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = pendingSeek ?? player.currentTime().seconds
        let duration = item.duration.seconds
        guard current.isFinite, duration.isFinite, duration > 0 else { return }
        let target = min(duration, max(0, current + seconds))
        pendingSeek = target
        let generation = UUID()
        seekGeneration = generation
        // Do not pause/play around a seek: AVPlayer preserves the current rate.
        // Accumulate rapid arrow presses while an earlier seek is still pending.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.pendingSeek = nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pendingSeek = nil
        seekGeneration = UUID()
    }

    func close() {
        removeKeyMonitor()
        let closingWindow = window
        playback?.stop()
        playback = nil
        window = nil
        closingWindow?.delegate = nil
        closingWindow?.close()
        closingWindow?.contentViewController = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        // The red close button must save progress and cancel byte requests too.
        removeKeyMonitor()
        playback?.stop()
        playback = nil
        window = nil
        closingWindow.delegate = nil
        closingWindow.contentViewController = nil
    }
}

private struct VideoSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Buffering UI updates must not reattach the same player to its view.
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
#endif
