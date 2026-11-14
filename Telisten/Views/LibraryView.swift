import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Window bounds stay stable when the keyboard appears, unlike the proposed
/// SwiftUI content size. Read the hosting window, not UIScreen.main, for scenes.
private struct PlayerWindowSizeReader: UIViewRepresentable {
    @Binding var size: CGSize
    @Binding var displayMidpoint: CGFloat?

    func makeUIView(context: Context) -> ObserverView { ObserverView() }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onSizeChange = { newSize, midpoint in
            size = newSize
            displayMidpoint = midpoint
        }
        view.reportSize()
    }

    final class ObserverView: UIView {
        var onSizeChange: ((CGSize, CGFloat) -> Void)?
        private var lastSize: CGSize = .zero
        private var lastMidpoint: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportSize()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportSize()
        }

        func reportSize() {
            guard let window else { return }
            let size = window.bounds.size
            let screen = window.screen
            let midpoint = convert(
                CGPoint(x: screen.bounds.midX, y: screen.bounds.midY),
                from: screen.coordinateSpace
            ).y
            guard size != lastSize || midpoint != lastMidpoint else { return }
            lastSize = size
            lastMidpoint = midpoint
            Task { @MainActor [weak self] in
                guard let self, self.window?.bounds.size == size else { return }
                self.onSizeChange?(size, midpoint)
            }
        }
    }
}
#endif

private struct BatchPlaylistSelection: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @AppStorage("video.enabled") private var videoEnabled = false
    @State private var showVideos = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if DEBUG
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("--demo-settings")
    #else
    @State private var showSettings = false
    #endif
    @State private var showSettingsAfterPlayerDismissal = false
    @State private var showDeletePlaylistConfirmation = false
    @State private var isEditingPlaylist = false
    @State private var playlistTitleDraft = ""
    @State private var isSelectingTracks = false
    @State private var selectedTrackIDs: Set<String> = []
    @State private var batchPlaylistSelection: BatchPlaylistSelection?
    @State private var showBatchRemovalConfirmation = false
    @State private var batchRemovalTracks: [Track] = []
    @State private var batchRemovalPlaylist: MusicChat?
    @State private var batchRemovalSource: SidebarSelection?
    @State private var batchRemovalAccountID: String?
    @State private var isPerformingBatchAction = false
    @FocusState private var playlistTitleFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var windowSize: CGSize = .zero
    @State private var displayMidpoint: CGFloat?
    #elseif os(macOS)
    @State private var showsDesktopLyrics = false
    #endif

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let wideLayout = horizontalSizeClass == .regular
            #else
            let wideLayout = true
            #endif
            libraryColumns(wideLayout: wideLayout, geometry: geometry)
            .onChange(of: model.selected) { value in
                finishSelectingTracks()
                Task { await model.select(value) }
            }
            .onChange(of: model.activeAccountID) { _ in finishSelectingTracks() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.player.track != nil, !model.showNowPlaying, !isSelectingTracks {
                    #if os(macOS)
                    PlayerBar(
                        model: model,
                        showsLyrics: $showsDesktopLyrics,
                        bottomSafeArea: geometry.safeAreaInsets.bottom
                    )
                    #else
                    PlayerBar(
                        model: model, bottomSafeArea: geometry.safeAreaInsets.bottom,
                        usesWideLayout: wideLayout
                    )
                    #endif
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: compactPlayerPresentation(wideLayout: wideLayout), onDismiss: presentPendingSettings) {
                NowPlayingView(model: model, presentationDetent: .constant(.large), showsCloseButton: true)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            .onChange(of: wideLayout) { isWide in
                if isWide { columnVisibility = .all }
            }
            #else
            .sheet(isPresented: $model.showNowPlaying, onDismiss: presentPendingSettings) {
                NowPlayingView(model: model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            #endif
            .overlay(alignment: .top) {
                if let message = model.favoritesMessage {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .task(id: model.favoritesMessage) {
                guard model.favoritesMessage != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                model.favoritesMessage = nil
            }
            .sheet(isPresented: $model.showPlaylistSheet) {
                if let track = model.playlistTrack {
                    PlaylistSheet(model: model, track: track)
                }
            }
            .sheet(item: $batchPlaylistSelection) { selection in
                BatchPlaylistSheet(model: model, tracks: selection.tracks) { savedID in
                    selectedTrackIDs.remove(savedID)
                    if selectedTrackIDs.isEmpty { finishSelectingTracks() }
                }
            }
            .confirmationDialog(
                batchRemovalTitle,
                isPresented: $showBatchRemovalConfirmation,
                titleVisibility: .visible,
                presenting: batchRemovalTracks
            ) { _ in
                Button("Remove", role: .destructive) { removeSelectedTracks() }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(batchRemovalMessage)
            }
            .sheet(isPresented: $model.showListenTogetherSheet) {
                ListenTogetherView(model: model)
            }
            .sheet(isPresented: $showVideos) {
                VideoLibraryView(library: model.makeVideoLibrary(), musicPlayer: model.player)
                    .id(model.activeAccountID)
            }
            .onChange(of: videoEnabled) { enabled in
                if !enabled {
                    showVideos = false
                    #if os(macOS)
                    VideoPlaybackWindow.shared.close()
                    #endif
                }
            }
            .onChange(of: model.activeAccountID) { _ in
                showVideos = false
                #if os(macOS)
                VideoPlaybackWindow.shared.close()
                #endif
            }
            #if os(macOS)
            .onDisappear { VideoPlaybackWindow.shared.close() }
            #endif
            .sheet(isPresented: $model.showBotSearch) {
                BotSearchConversationView(model: model)
                    #if os(macOS)
                    .frame(minWidth: 360, minHeight: 520)
                    #endif
            }
            .alert(
                "Delete playlist?",
                isPresented: $showDeletePlaylistConfirmation,
                presenting: selectedPlaylist
            ) { playlist in
                Button("Delete Playlist", role: .destructive) {
                    Task {
                        if await model.deletePlaylist(playlist) {
                            withAnimation { columnVisibility = .all }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { playlist in
                Text("This permanently deletes \(playlist.title) from Telegram. This cannot be undone.")
            }
        }
        #if os(iOS)
        .background { PlayerWindowSizeReader(size: $windowSize, displayMidpoint: $displayMidpoint) }
        #endif
    }

    @ViewBuilder
    private func libraryColumns(wideLayout: Bool, geometry: GeometryProxy) -> some View {
        #if os(iOS)
        if wideLayout, model.showNowPlaying, model.player.track != nil,
           (windowSize == .zero ? geometry.size.height > geometry.size.width : windowSize.height > windowSize.width) {
            // A tall inner display works as a tabletop: a viewing surface above
            // a touch surface. This is an aspect-ratio fallback, not hinge sensing.
            // Account for asymmetric system bars when locating the screen midpoint.
            let screenHeight = windowSize == .zero
                ? geometry.frame(in: .global).maxY + geometry.safeAreaInsets.bottom
                : windowSize.height
            let midpoint = displayMidpoint ?? (screenHeight / 2 - geometry.frame(in: .global).minY)
            // Keyboard avoidance can reduce the available height without changing
            // the device's arrangement. Give browsing room instead of switching panes.
            let upperHeight = min(midpoint, geometry.size.height * 0.48)
            TabletopPlayerView(model: model, upperRegionHeight: upperHeight) {
                NavigationStack {
                    if model.selected != nil {
                        trackBrowser
                    } else {
                        sidebar
                    }
                }
            }
        } else if wideLayout {
            // Two independent navigation roots keep both panes interactive. A
            // NavigationSplitView may overlay its sidebar at this aspect ratio.
            HStack(spacing: 0) {
                NavigationStack {
                    if model.showNowPlaying, model.selected != nil {
                        trackBrowser
                    } else {
                        sidebar
                    }
                }
                .frame(width: model.showNowPlaying ? geometry.size.width / 2 : min(260, geometry.size.width * 0.36))
                Divider()
                NavigationStack {
                    if model.showNowPlaying, model.player.track != nil {
                        NowPlayingView(
                            model: model, presentationDetent: .constant(.large),
                            showsCloseButton: true, isEmbedded: true
                        )
                    } else {
                        trackBrowser
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                trackBrowser
            }
        }
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            #if os(macOS)
            if showsDesktopLyrics, model.player.track != nil {
                DesktopLyricsView(model: model)
            } else {
                trackBrowser
            }
            #else
            trackBrowser
            #endif
        }
        #endif
    }

    #if os(iOS)
    private func compactPlayerPresentation(wideLayout: Bool) -> Binding<Bool> {
        Binding(
            get: { model.showNowPlaying && !wideLayout },
            set: { value in
                // Expanding the window moves playback into the detail pane;
                // dismissal of the old cover must not close that pane as well.
                if !wideLayout { model.showNowPlaying = value }
            }
        )
    }
    #endif

    private func openSettings() {
        #if os(iOS)
        // The sidebar remains interactive beside the embedded player. A cover
        // hides it in compact layouts, so an accessible Settings button here
        // can present directly without waiting for a cover's dismissal callback.
        showSettings = true
        #else
        guard model.showNowPlaying else {
            showSettings = true
            return
        }

        showSettingsAfterPlayerDismissal = true
        model.showNowPlaying = false
        #endif
    }

    private func presentPendingSettings() {
        guard showSettingsAfterPlayerDismissal else { return }
        showSettingsAfterPlayerDismissal = false
        showSettings = true
    }

    private var sidebar: some View {
        List(selection: $model.selected) {
            // Keep connection status inside the list so the navigation bar
            // retains its own safe area and its controls remain accessible.
            VideoConnectionStatusView(service: model.telegramConnectionService)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section("Library") {
                Label("Search all music", systemImage: "magnifyingglass.circle.fill")
                    .tag(SidebarSelection.globalSearch)
                Label("Favorites", systemImage: "heart.fill")
                    .tag(SidebarSelection.favorites)
                Label("Downloads", systemImage: "arrow.down.circle.fill")
                    .tag(SidebarSelection.downloads)
                if videoEnabled {
                    Button { showVideos = true } label: {
                        Label("Videos", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            if !model.searchBots.isEmpty {
                Section("Music Bots") {
                    ForEach(model.searchBots) { config in
                        botRow(config)
                    }
                }
            }
            if !model.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(model.playlists) { playlist in
                        HStack(spacing: 9) {
                            ChatAvatar(model: model, chat: playlist, size: 26, fallbackSymbol: "music.note.list")
                            Text(playlist.title)
                                .lineLimit(1)
                        }
                        .tag(SidebarSelection.chat(playlist.id))
                    }
                }
            }
            if !savedChats.isEmpty {
                Section("Saved Chats") {
                    ForEach(savedChats) { chat in
                        chatRow(chat)
                    }
                }
            }
            if model.showChats {
                Section("All Chats") {
                    ForEach(unsavedChats) { chat in
                        chatRow(chat)
                    }
                    if model.isIndexingChats {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Finding music sources…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if nonPlaylistChats.isEmpty {
                        Text("No music chats found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if unsavedChats.isEmpty {
                        Text("All music chats are saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS) || os(visionOS)
            ToolbarItem(placement: .topBarLeading) { accountMenu }
            #else
            ToolbarItem(placement: .navigation) { accountMenu }
            #endif
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button("Listen Together", systemImage: "dot.radiowaves.left.and.right") {
                        model.showListenTogetherSheet = true
                    }
                    Button("Settings", systemImage: "gearshape", action: openSettings)
                }
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    Task { await model.switchAccount(to: account) }
                } label: {
                    Label(
                        account.displayName,
                        systemImage: account.id == model.activeAccountID
                            ? "checkmark.circle.fill"
                            : "person.crop.circle"
                    )
                }
                .disabled(account.id == model.activeAccountID)
            }
            if !model.accounts.isEmpty { Divider() }
            Button("Add Account", systemImage: "person.badge.plus") {
                Task { await model.addAccount() }
            }
        } label: {
            HStack(spacing: 6) {
                if let account = model.activeAccount {
                    AccountAvatar(model: model, account: account, size: 28)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }
                #if os(iOS)
                if horizontalSizeClass != .regular {
                    Text(model.activeAccount?.displayName ?? "Account")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                #else
                Text(model.activeAccount?.displayName ?? "Account")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .accessibilityLabel("Telegram account")
    }

    private var nonPlaylistChats: [MusicChat] {
        let playlistIDs = Set(model.playlists.map(\.id))
        return model.chats.filter { !playlistIDs.contains($0.id) }
    }

    private var savedChats: [MusicChat] {
        nonPlaylistChats.filter { model.savedChatIDs.contains($0.id) }
    }

    private var unsavedChats: [MusicChat] {
        nonPlaylistChats.filter { !model.savedChatIDs.contains($0.id) }
    }

    private func chatRow(_ chat: MusicChat) -> some View {
        HStack(spacing: 9) {
            ChatAvatar(model: model, chat: chat, size: 26)
            Text(chat.title)
                .lineLimit(1)
            Spacer(minLength: 6)
            if chat.isPinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityLabel("Pinned chat")
            }
        }
        .tag(SidebarSelection.chat(chat.id))
        .contextMenu {
            Button(
                model.savedChatIDs.contains(chat.id) ? "Remove from Saved Chats" : "Save Chat",
                systemImage: model.savedChatIDs.contains(chat.id) ? "bookmark.slash" : "bookmark"
            ) {
                model.toggleSavedChat(chat)
            }
        }
    }

    private func botRow(_ config: SearchBotConfig) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(Color.telistenAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(config.displayBotName)
                .lineLimit(1)
            Spacer(minLength: 6)
            if model.selected == .bot(config.id), model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.openBotSearch(using: config) }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.telistenAccent)
            .accessibilityLabel("Chat with \(config.displayBotName)")
            .accessibilityHint("Opens the interactive Telegram bot conversation")
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.bot(config.id))
        .accessibilityLabel("Music from \(config.displayBotName)")
        .accessibilityHint("Shows audio received from this bot")
    }

    private var trackBrowser: some View {
        VStack(spacing: 0) {
            if isSelectingTracks { trackSelectionHeader }
            if model.isGlobalSearch {
                trackList(includeSearchBots: true)
            } else {
                if model.isLoading && model.tracks.isEmpty {
                    ProgressView("Finding music…")
                } else if model.tracks.isEmpty {
                    emptyTracksPlaceholder
                } else {
                    trackList(includeSearchBots: false)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingTracks { batchActionsBar }
        }
        .navigationTitle(isEditingPlaylist && selectedPlaylist != nil ? "" : localizedUI(browserTitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(usesCompactBackButton)
        .toolbar(.visible, for: .navigationBar)
        .simultaneousGesture(detailBackGesture)
        #endif
        #if os(iOS)
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: model.isGlobalSearch ? "Song, artist, or album" : "Search music here"
        )
        #else
        .searchable(
            text: $model.searchText,
            prompt: model.isGlobalSearch ? "Song, artist, or album" : "Search music here"
        )
        #endif
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.searchText) { query in
            finishSelectingTracks()
            if query.isEmpty && (model.selected == .favorites || model.selected == .downloads) {
                Task { await model.search() }
            }
        }
        .onChange(of: model.tracks.map(\.id)) { ids in
            selectedTrackIDs.formIntersection(ids)
        }
        .onChange(of: model.selectedChat?.id) { _ in
            isEditingPlaylist = false
            playlistTitleDraft = selectedPlaylist?.title ?? ""
        }
        .onChange(of: isEditingPlaylist) { isEditing in
            if isEditing {
                if let playlist = selectedPlaylist {
                    playlistTitleDraft = playlist.title
                }
            } else {
                commitPlaylistTitle()
                playlistTitleFocused = false
            }
        }
        .toolbar(content: { trackBrowserToolbar })
    }

    @ToolbarContentBuilder
    private var trackBrowserToolbar: some ToolbarContent {
            ToolbarItem(placement: .principal) {
                if let playlist = selectedPlaylist, isEditingPlaylist {
                    HStack(spacing: 7) {
                        TextField("Playlist name", text: $playlistTitleDraft)
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .submitLabel(.done)
                            .focused($playlistTitleFocused)
                            .onSubmit {
                                commitPlaylistTitle()
                                playlistTitleFocused = false
                            }
                            .accessibilityLabel("Playlist title")
                        if model.renamingPlaylistIDs.contains(playlist.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 180)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.28))
                            .frame(height: 1)
                    }
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                if usesCompactBackButton {
                    Button(action: returnToLibrary) {
                        Label("Library", systemImage: "chevron.left")
                    }
                }
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                if let playlist = selectedPlaylist, !isSelectingTracks {
                    if !usesListeningSpread {
                        Button(
                            model.isDownloadingAll(in: playlist) ? "Downloading" : "Download all",
                            systemImage: "arrow.down.circle"
                        ) {
                            model.downloadAll(in: playlist)
                        }
                        .disabled(model.isDownloadingAll(in: playlist))
                        Button(isEditingPlaylist ? "Done" : "Edit") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isEditingPlaylist.toggle()
                            }
                        }
                    }
                    if !isEditingPlaylist || usesListeningSpread {
                        Menu("Playlist actions", systemImage: "ellipsis.circle") {
                            if usesListeningSpread {
                                Button("Download all", systemImage: "arrow.down.circle") {
                                    model.downloadAll(in: playlist)
                                }
                                .disabled(model.isDownloadingAll(in: playlist))
                                Button(isEditingPlaylist ? "Done" : "Edit", systemImage: "pencil") {
                                    isEditingPlaylist.toggle()
                                }
                            }
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await model.search() }
                            }
                            Divider()
                            Text("Track order is saved on this device")
                            if playlist.kind == .channel {
                                Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                    showDeletePlaylistConfirmation = true
                                }
                            }
                        }
                        .disabled(model.isDeletingPlaylist)
                    }
                } else if !model.isGlobalSearch && !isSelectingTracks {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.search() }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if isSelectingTracks {
                        finishSelectingTracks()
                    } else {
                        selectedTrackIDs.removeAll()
                        isSelectingTracks = true
                    }
                } label: {
                    Label(localizedUI(isSelectingTracks ? "Done" : "Select songs"),
                          systemImage: isSelectingTracks ? "checkmark" : "checklist")
                }
                .disabled(isPerformingBatchAction || (!isSelectingTracks && (model.tracks.isEmpty || isEditingPlaylist)))
                .accessibilityIdentifier("tracks.select")
            }
    }

    private var selectedTracks: [Track] {
        model.tracks.filter { selectedTrackIDs.contains($0.id) }
    }

    private var allTracksSelected: Bool {
        !model.tracks.isEmpty && selectedTrackIDs.isSuperset(of: model.tracks.map(\.id))
    }

    private var removableSelectedTracks: [Track] {
        if selectedPlaylist != nil || model.selected == .favorites { return selectedTracks }
        return selectedTracks.filter {
            model.cachedIDs.contains($0.id) && model.downloads[$0.id]?.isDownloading != true
        }
    }

    private var trackSelectionHeader: some View {
        HStack {
            Button {
                if allTracksSelected { selectedTrackIDs.removeAll() }
                else { selectedTrackIDs = Set(model.tracks.map(\.id)) }
            } label: {
                Label(localizedUI(allTracksSelected ? "Deselect all" : (model.hasMoreTracks ? "Select all shown" : "Select all")),
                      systemImage: allTracksSelected ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.telistenAccent)
            .accessibilityIdentifier("tracks.selectAll")
            Spacer()
            Text(String(format: localizedUI("%lld selected"), Int64(selectedTracks.count)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.telistenBackground)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(isPerformingBatchAction)
    }

    private func selectableTrackRow(_ track: Track) -> some View {
        let isSelected = selectedTrackIDs.contains(track.id)
        return Button {
            if isSelected { selectedTrackIDs.remove(track.id) }
            else { selectedTrackIDs.insert(track.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.telistenAccent : .secondary)
                    .frame(width: 24)
                TrackArtwork(model: model, track: track, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(track.displayArtist)  •  \(DisplayFormat.duration(track.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.cachedIDs.contains(track.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Downloaded")
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowBackground(isSelected ? Color.telistenAccent.opacity(0.08) : Color.clear)
        .accessibilityLabel("\(track.displayTitle), \(track.displayArtist)")
        .accessibilityValue(localizedUI(isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var batchActionsBar: some View {
        HStack(spacing: 0) {
            batchAction("Play", symbol: "play.fill") {
                let values = selectedTracks
                if let first = values.first { model.play(first, from: values) }
                finishSelectingTracks()
            }
            batchAction("Add to…", symbol: "text.badge.plus") {
                batchPlaylistSelection = BatchPlaylistSelection(tracks: selectedTracks)
            }
            batchAction("Download", symbol: "arrow.down.circle") {
                model.cacheTracks(selectedTracks)
                finishSelectingTracks()
            }
            batchAction("Remove", symbol: "trash") {
                batchRemovalTracks = removableSelectedTracks
                batchRemovalPlaylist = selectedPlaylist
                batchRemovalSource = model.selected
                batchRemovalAccountID = model.activeAccountID
                showBatchRemovalConfirmation = true
            }
            .disabled(removableSelectedTracks.isEmpty)
            .opacity(removableSelectedTracks.isEmpty ? 0.35 : 1)
        }
        .opacity(selectedTracks.isEmpty || isPerformingBatchAction ? 0.4 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .disabled(selectedTracks.isEmpty || isPerformingBatchAction)
    }

    private func batchAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(localizedUI(title)).font(.caption)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.telistenAccent)
        .accessibilityLabel(localizedUI(title))
    }

    private var batchRemovalTitle: String {
        localizedUI(batchRemovalPlaylist != nil ? "Remove from playlist" :
                    (batchRemovalSource == .favorites ? "Remove from Favorites" : "Remove downloads"))
    }

    private var batchRemovalMessage: String {
        let key = batchRemovalPlaylist != nil
            ? "Remove %lld songs from this playlist? Their messages in this playlist will be deleted."
            : (batchRemovalSource == .favorites
               ? "Remove %lld songs from Favorites?"
               : "Remove downloaded files for %lld songs? You can download them again.")
        return String(format: localizedUI(key), Int64(batchRemovalTracks.count))
    }

    private func finishSelectingTracks() {
        isSelectingTracks = false
        selectedTrackIDs.removeAll()
        batchPlaylistSelection = nil
        showBatchRemovalConfirmation = false
    }

    private func removeSelectedTracks() {
        guard model.activeAccountID == batchRemovalAccountID else { return }
        let values = batchRemovalTracks
        if let playlist = batchRemovalPlaylist {
            let accountID = batchRemovalAccountID
            isPerformingBatchAction = true
            Task {
                defer { isPerformingBatchAction = false }
                var failedIDs: Set<String> = []
                var failure: String?
                for track in values {
                    guard model.activeAccountID == accountID else { return }
                    await model.delete(track, from: playlist)
                    if let error = model.errorMessage {
                        failedIDs.insert(track.id)
                        failure = error
                        model.errorMessage = nil
                    }
                }
                guard model.activeAccountID == accountID else { return }
                selectedTrackIDs = failedIDs
                if failedIDs.isEmpty { finishSelectingTracks() }
                if let failure { model.errorMessage = failure }
            }
        } else {
            if batchRemovalSource == .favorites { model.removeFavorites(values) }
            else { model.removeDownloads(values) }
            finishSelectingTracks()
        }
    }

    private var emptyTracksPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySymbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(localizedUI(emptyTitle))
                .font(.headline)
            Text(localizedUI(emptyDescription))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func trackList(includeSearchBots: Bool) -> some View {
        List {
            if includeSearchBots {
                SearchBotProvidersView(model: model, query: model.searchText)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if model.isLoading && model.tracks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Finding music…")
                    Spacer()
                }
                .frame(minHeight: 160)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if model.tracks.isEmpty {
                emptyTracksPlaceholder
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.tracks) { track in
                    Group {
                        if isSelectingTracks { selectableTrackRow(track) }
                        else { TrackRow(model: model, track: track) }
                    }
                        .disabled(isPerformingBatchAction)
                        .moveDisabled(selectedPlaylist == nil || isSelectingTracks)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let playlist = selectedPlaylist, !isSelectingTracks {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(track, from: playlist) }
                                }
                                .disabled(model.deletingPlaylistTrackIDs.contains(track.id))
                            }
                        }
                }
                .onMove { source, destination in
                    model.moveTracks(from: source, to: destination)
                }
            }

            if model.hasMoreTracks {
                VStack(spacing: 8) {
                    if let error = model.loadMoreError {
                        Text(localizedUI(error))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry loading songs") {
                            Task { await model.loadMoreTracks() }
                        }
                        .disabled(model.isLoadingMore)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .onAppear { Task { await model.loadMoreTracks() } }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 54)
        #if os(iOS)
        .environment(
            \.editMode,
            Binding(
                get: { isEditingPlaylist ? .active : .inactive },
                set: { isEditingPlaylist = $0.isEditing }
            )
        )
        #endif
    }

    private var usesListeningSpread: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular && model.showNowPlaying
        #else
        false
        #endif
    }

    private var selectedPlaylist: MusicChat? {
        guard let chat = model.selectedChat else { return nil }
        return model.playlists.first { $0.id == chat.id }
    }

    private func commitPlaylistTitle() {
        guard let playlist = selectedPlaylist else { return }
        let title = playlistTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != playlist.title else {
            playlistTitleDraft = playlist.title
            return
        }
        Task {
            if await model.renamePlaylist(playlist, to: title) {
                playlistTitleDraft = title
            }
        }
    }

    #if os(iOS)
    private var usesCompactBackButton: Bool {
        (horizontalSizeClass == .compact || model.showNowPlaying) && model.selected != nil
    }

    private var canSwipeBackFromDetail: Bool {
        (horizontalSizeClass == .compact || model.showNowPlaying) && model.selected != nil
    }

    private var detailBackGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onEnded { value in
                guard canSwipeBackFromDetail,
                      value.startLocation.x <= 28,
                      value.translation.width > 64,
                      value.translation.width > abs(value.translation.height) * 1.25 else { return }
                returnToLibrary()
            }
    }

    private func returnToLibrary() {
        if isEditingPlaylist {
            isEditingPlaylist = false
        }
        withAnimation(.easeOut(duration: 0.2)) {
            model.selected = nil
            columnVisibility = .all
        }
    }
    #endif

    private var browserTitle: String {
        return switch model.selected {
        case .globalSearch: "Search All Music"
        case .favorites: "Favorites"
        case .downloads: "Downloads"
        case let .bot(id): model.searchBots.first(where: { $0.id == id })?.displayBotName ?? "Music Bot"
        case .chat: model.selectedChat?.title ?? "Music"
        case nil: "Music"
        }
    }

    private var emptyTitle: String {
        switch model.selected {
        case .globalSearch: "Search all music"
        case .favorites: "No favorites yet"
        case .downloads: "Nothing downloaded"
        case .bot: "No music from this bot"
        case .chat: "No music found"
        case nil: "Choose music"
        }
    }

    private var emptySymbol: String {
        switch model.selected {
        case .globalSearch: "magnifyingglass.circle"
        case .favorites: "heart"
        case .downloads: "arrow.down.circle"
        default: "music.note.list"
        }
    }

    private var emptyDescription: String {
        switch model.selected {
        case .globalSearch: "Find songs, artists, or albums across your Telegram music."
        case .favorites: "Tap the heart beside a track to keep it here."
        case .downloads: "Downloaded music remains available offline."
        case .bot: "Use the chat button to ask the bot for music, then return here to play it."
        case .chat: "Try another search or choose a different music source."
        case nil: "Pick a playlist, favorite, download, or music source from the sidebar."
        }
    }
}

private struct TrackRow: View {
    @ObservedObject var model: AppModel
    let track: Track

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.play(track)
                } label: {
                    HStack(spacing: 10) {
                        TrackArtwork(model: model, track: track, size: 44)
                            .overlay(alignment: .center) {
                                if isCurrent && model.player.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                } else if isCurrent && model.player.isPlaying {
                                    Image(systemName: "waveform")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if model.cachedIDs.contains(track.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.green)
                                        .background(.background, in: Circle())
                                        .offset(x: 3, y: 3)
                                        .accessibilityLabel("Downloaded")
                                }
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayTitle)
                                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(isCurrent ? Color.telistenAccent : .primary)
                            Text(metadata)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
                favoriteButton
                moreMenu
            }
            .padding(.vertical, 6)

            downloadProgress

            Divider()
                .padding(.leading, 54)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Play", systemImage: "play.fill") { model.play(track) }
            Button("Add to…", systemImage: "text.badge.plus") { model.openPlaylistPicker(for: track) }
            if model.cachedIDs.contains(track.id) {
                Button("Remove download", systemImage: "trash", role: .destructive) { model.removeDownload(track) }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.cacheTrack(track) }
            }
        }
    }

    private var favoriteButton: some View {
        Button {
            model.toggleFavorite(track)
        } label: {
            Image(systemName: model.isFavorite(track) ? "heart.fill" : "heart")
                .font(.callout)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isFavorite(track) ? Color.telistenAccent : .secondary)
        .accessibilityLabel(localizedUI(model.isFavorite(track) ? "Unfavorite" : "Favorite"))
    }

    @ViewBuilder private var downloadProgress: some View {
        let status = model.downloads[track.id] ?? .none
        if status.isDownloading, !status.isCached {
            ProgressView(value: status.progress)
                .progressViewStyle(.linear)
                .tint(Color.telistenAccent)
                .padding(.leading, 54)
                .padding(.trailing, 8)
                .accessibilityLabel("Downloading \(track.displayTitle)")
                .accessibilityValue("\(Int(status.progress * 100)) percent")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Add to…", systemImage: "text.badge.plus") {
                model.openPlaylistPicker(for: track)
            }
            if model.cachedIDs.contains(track.id) {
                Button("Remove download", systemImage: "trash", role: .destructive) {
                    model.removeDownload(track)
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    model.cacheTrack(track)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("More actions for \(track.displayTitle)")
    }

    private var metadata: String {
        track.duration > 0
            ? "\(track.displayArtist)  •  \(DisplayFormat.duration(track.duration))"
            : track.displayArtist
    }

    private var isCurrent: Bool { model.player.track?.id == track.id }
}
