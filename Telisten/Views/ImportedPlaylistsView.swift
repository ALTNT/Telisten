import SwiftUI

struct ImportedPlaylistsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharedText = ""
    @State private var preview: ImportedPlaylist?
    @State private var importError: String?
    @State private var isReading = false
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Text(localizedUI(error)).foregroundStyle(.red)
                        Button("OK") { model.errorMessage = nil }
                    }
                }
                Section("Import playlist") {
                    TextField("NetEase or QQ Music playlist link", text: $sharedText)
                        .lineLimit(1...3)
                    Button("Read playlist") { readPlaylist() }
                        .disabled(isReading || sharedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isReading { ProgressView("Reading playlist…") }
                    if let importError { Text(localizedUI(importError)).foregroundStyle(.red) }
                    Text("Import saves the song list. Telegram sync shares it with your other devices. During playback, Telisten prepares the next song in advance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("Preview") {
                        Text(preview.title).font(.headline)
                        Text("\(preview.entries.count) / \(preview.expectedCount) songs")
                        if !preview.isComplete {
                            Text("The platform returned an incomplete song list or missing metadata. You can save this partial snapshot and try updating it later.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(preview.entries.prefix(5)) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.title.isEmpty ? entry.songID : entry.title)
                                Text(entry.artists.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(model.importedPlaylists.contains(where: { $0.id == preview.id }) ? "Update imported playlist" : "Save imported playlist") {
                            if model.saveImportedPlaylist(preview) {
                                self.preview = nil
                                sharedText = ""
                            }
                        }
                        .disabled(preview.entries.isEmpty && preview.expectedCount > 0)
                    }
                }
                Section("Playback bot") {
                    Picker("MusicBot", selection: $model.importedPlaylistBotID) {
                        Text("Choose a bot").tag(Optional<UUID>.none)
                        ForEach(model.searchBots) { bot in
                            Text(bot.displayBotName).tag(Optional(bot.id))
                        }
                    }
                    Text("Choose a bot that supports /music with NetEase and QQ Music song links. Add bots in Settings first. The bot's default quality is used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Telegram sync") {
                    Toggle("Sync imported playlists", isOn: $model.importedPlaylistSyncEnabled)
                    Toggle("Sync Favorites", isOn: $model.favoriteSyncEnabled)
                    if model.isSyncingImportedPlaylists {
                        ProgressView("Syncing…")
                    }
                    if let date = model.importedPlaylistSyncState.lastSyncedAt {
                        LabeledContent("Imported playlists last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if model.favoriteSyncEnabled {
                        if let date = model.favoriteSyncLastSyncedAt {
                            LabeledContent("Favorites last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if model.favoriteSyncUnresolvedCount > 0 {
                            Text("Favorites awaiting audio recovery: \(model.favoriteSyncUnresolvedCount)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.importedPlaylistSyncState.pending.isEmpty {
                        Text("\(model.importedPlaylistSyncState.pending.count) changes waiting to sync")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.importedPlaylistSyncError {
                        Text(localizedUI(error)).font(.caption).foregroundStyle(.red)
                    }
                    if let error = model.favoriteSyncError, error != model.importedPlaylistSyncError {
                        Text(localizedUI(error)).font(.caption).foregroundStyle(.red)
                    }
                    Button("Sync now") { Task { await model.syncImportedPlaylists() } }
                        .disabled(!(model.importedPlaylistSyncEnabled || model.favoriteSyncEnabled)
                            || model.isSyncingImportedPlaylists || model.isDemo || model.activeAccountID == nil)
                    if !model.importedPlaylistSyncState.conflicts.isEmpty {
                        NavigationLink {
                            ImportedPlaylistSyncConflictsView(model: model)
                        } label: {
                            Text("Resolve sync conflicts")
                        }
                        .badge(model.importedPlaylistSyncState.conflicts.count)
                    }
                    Text("Uses a private Telisten Sync channel in this Telegram account. Audio downloads stay on each device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Imported playlists") {
                    ForEach(model.importedPlaylists) { playlist in
                        NavigationLink {
                            ImportedPlaylistDetailView(model: model, playlistID: playlist.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.title)
                                Text("\(playlist.platform.title) · \(playlist.entries.count) / \(playlist.expectedCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { model.importedPlaylists.indices.contains($0) ? model.importedPlaylists[$0].id : nil }
                        for id in ids { model.deleteImportedPlaylist(id) }
                    }
                }
            }
            .navigationTitle("Imported playlists")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { readTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func readPlaylist() {
        readTask?.cancel()
        preview = nil
        importError = nil
        isReading = true
        let text = sharedText
        let accountID = model.activeAccountID
        readTask = Task { @MainActor in
            defer { isReading = false }
            do {
                let result = try await PlaylistImportService().preview(text)
                guard !Task.isCancelled, model.activeAccountID == accountID else { return }
                preview = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, model.activeAccountID == accountID else { return }
                importError = error.localizedDescription
            }
        }
    }
}

private struct ImportedPlaylistSyncConflictsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Text("This device and another device changed the same item. Choose which version to keep.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.importedPlaylistSyncState.conflicts.values.sorted { $0.id < $1.id }) { conflict in
                Section {
                    Text(title(conflict)).font(.headline)
                    LabeledContent("This device", value: summary(conflict.local))
                    LabeledContent("Synced version", value: summary(conflict.remote))
                    Button("Keep this device's change") {
                        model.resolveImportedPlaylistSyncConflict(conflict.id, keepingLocal: true)
                    }
                    Button("Use synced change") {
                        model.resolveImportedPlaylistSyncConflict(conflict.id, keepingLocal: false)
                    }
                }
            }
        }
        .navigationTitle("Resolve sync conflicts")
    }

    private func title(_ conflict: ImportedPlaylistSyncConflict) -> String {
        let record = conflict.local
        switch record.kind {
        case .playlist: return record.playlist?.title ?? conflict.remote.playlist?.title ?? record.playlistID ?? ""
        case .source:
            return model.importedPlaylists.first { $0.id == record.playlistID }?.entries.first { $0.songID == record.songID }?.title
                ?? localizedUI("Song audio")
        case .bot: return localizedUI("Playback bot")
        }
    }

    private func summary(_ record: ImportedPlaylistSyncRecord) -> String {
        switch record.kind {
        case .playlist:
            guard let playlist = record.playlist else { return localizedUI("Deleted playlist") }
            return "\(playlist.title) · \(playlist.entries.count)"
        case .source: return localizedUI(record.source == nil ? "No matched audio" : "Matched audio")
        case .bot: return record.bot.map { "@\($0.username) \($0.prefix)…\($0.suffix)" } ?? localizedUI("Choose a bot")
        }
    }
}

struct ImportedPlaylistDetailView: View {
    private struct AddSelection: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    @ObservedObject var model: AppModel
    var playlistID: String
    @State private var choosingSource: ImportedPlaylistEntry?
    @State private var isSelecting = false
    @State private var selectedEntryIDs: Set<String> = []
    @State private var addSelection: AddSelection?
    @State private var addTask: Task<Void, Never>?
    @State private var addOperationID: UUID?
    @State private var addCompletedCount = 0
    @State private var addTotalCount = 0
    @State private var addMessage: String?

    private var playlist: ImportedPlaylist? { model.importedPlaylists.first { $0.id == playlistID } }

    var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Text(localizedUI(error)).foregroundStyle(.red)
                    Button("OK") { model.errorMessage = nil }
                }
            }
            if let playlist {
                Section {
                    Link("Open original playlist", destination: playlist.sourceURL)
                    Text("\(playlist.entries.count) / \(playlist.expectedCount) songs")
                    if !isSelecting {
                        Button {
                            model.playImportedEntries(Set(playlist.entries.map(\.id)), in: playlist.id)
                        } label: {
                            Label("Play all", systemImage: "play.fill")
                        }
                        .disabled(playlist.entries.isEmpty || model.resolvingImportedEntryID != nil)
                    }
                    if model.resolvingImportedEntryID != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for music bot…")
                            Spacer()
                            Button("Cancel") { model.cancelImportedPlayback() }
                        }
                    }
                }
                if isSelecting {
                    Section {
                        let allIDs = Set(playlist.entries.map(\.id))
                        let allSelected = !allIDs.isEmpty && selectedEntryIDs.isSuperset(of: allIDs)
                        Button(localizedUI(allSelected ? "Deselect all" : "Select all")) {
                            selectedEntryIDs = allSelected ? [] : allIDs
                        }
                        Text(String(format: localizedUI("%lld selected"), Int64(selectedEntryIDs.count)))
                            .foregroundStyle(.secondary)
                        Button {
                            model.playImportedEntries(selectedEntryIDs, in: playlist.id)
                            finishSelecting()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .disabled(selectedEntryIDs.isEmpty || model.resolvingImportedEntryID != nil)
                        Button {
                            prepareToAdd(playlist.entries.filter { selectedEntryIDs.contains($0.id) })
                        } label: {
                            Label("Add to…", systemImage: "text.badge.plus")
                        }
                        .disabled(selectedEntryIDs.isEmpty || addTask != nil)
                    }
                }
                if addTask != nil || addMessage != nil {
                    Section {
                        if addTask != nil {
                            ProgressView("Preparing selected audio…", value: Double(addCompletedCount),
                                         total: Double(addTotalCount))
                            Button("Cancel") { cancelAdd() }
                        }
                        if let addMessage { Text(addMessage).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    ForEach(playlist.entries) { entry in
                        Button {
                            if isSelecting {
                                if !selectedEntryIDs.insert(entry.id).inserted { selectedEntryIDs.remove(entry.id) }
                            } else {
                                model.playImportedEntry(entry.id, in: playlist.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelecting
                                      ? (selectedEntryIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                      : statusSymbol(entry))
                                    .foregroundStyle(Color.telistenAccent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title.isEmpty ? entry.songID : entry.title).lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(entry.artists.joined(separator: " / "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if let reason = model.importedPlaylistErrors[playlist.id]?[entry.id] {
                                        Text("Temporarily unavailable. Tap to retry.")
                                            .font(.caption).foregroundStyle(.orange)
                                            .help(reason)
                                    }
                                }
                                Spacer()
                                if model.playingImportedPlaylistID == playlist.id && model.playingImportedEntryID == entry.id {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.telistenAccent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!isSelecting && model.resolvingImportedEntryID != nil)
                        .accessibilityAddTraits(isSelecting && selectedEntryIDs.contains(entry.id) ? .isSelected : [])
                        .contextMenu {
                            if !isSelecting {
                                Button("Add to…") { prepareToAdd([entry]) }.disabled(addTask != nil)
                                Link("Open original song", destination: entry.songURL)
                                Button("Choose received audio") { choosingSource = entry }
                                if entry.track != nil || model.importedPlaylistSyncState.source(playlistID: playlist.id, songID: entry.songID) != nil {
                                    Button("Forget matched audio") {
                                        model.clearImportedSource(playlistID: playlist.id, entryID: entry.id)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("A cloud icon means audio has not been matched. A checkmark means audio is matched. A download icon means it is available offline.")
                }
            }
        }
        .navigationTitle(playlist?.title ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(localizedUI(isSelecting ? "Done" : "Select songs")) {
                    if isSelecting { finishSelecting() }
                    else { isSelecting = true }
                }
                .disabled(!isSelecting && playlist?.entries.isEmpty != false)
            }
        }
        .onChange(of: playlist?.entries.map(\.id)) { ids in
            selectedEntryIDs.formIntersection(ids ?? [])
        }
        .onChange(of: model.activeAccountID) { _ in
            cancelAdd()
            finishSelecting()
            addSelection = nil
            addMessage = nil
        }
        .onDisappear { cancelAdd() }
        .sheet(item: $choosingSource) { entry in
            ImportedAudioPicker(model: model, playlistID: playlistID, entry: entry)
                .allowsApplicationTermination()
                .id(model.activeAccountID)
        }
        .sheet(item: $addSelection) { selection in
            BatchPlaylistSheet(model: model, tracks: selection.tracks) { trackID in
                for entry in playlist?.entries ?? [] where entry.track?.id == trackID {
                    selectedEntryIDs.remove(entry.id)
                }
            }
            .allowsApplicationTermination()
            .id(model.activeAccountID)
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selectedEntryIDs.removeAll()
    }

    private func prepareToAdd(_ entries: [ImportedPlaylistEntry]) {
        guard addTask == nil, !entries.isEmpty else { return }
        let operationID = UUID()
        let accountID = model.activeAccountID
        addOperationID = operationID
        addCompletedCount = 0
        addTotalCount = entries.count
        addMessage = nil
        addTask = Task {
            defer {
                if addOperationID == operationID { addTask = nil }
            }
            var tracks: [Track] = []
            var seen: Set<String> = []
            var failures = 0
            var lastError: String?
            for entry in entries {
                guard !Task.isCancelled, model.activeAccountID == accountID else { return }
                do {
                    let track = try await model.prepareImportedTrack(entry.id, in: playlistID)
                    if seen.insert(track.id).inserted { tracks.append(track) }
                } catch {
                    failures += 1
                    lastError = error.localizedDescription
                }
                guard addOperationID == operationID else { return }
                addCompletedCount += 1
            }
            guard !Task.isCancelled, model.activeAccountID == accountID,
                  addOperationID == operationID else { return }
            if failures > 0 {
                addMessage = tracks.isEmpty ? lastError
                    : String(format: localizedUI("Could not prepare %lld selected songs."), Int64(failures))
            }
            if !tracks.isEmpty { addSelection = AddSelection(tracks: tracks) }
        }
    }

    private func cancelAdd() {
        addTask?.cancel()
        addTask = nil
        addOperationID = nil
    }

    private func statusSymbol(_ entry: ImportedPlaylistEntry) -> String {
        if model.importedPlaylistErrors[playlistID]?[entry.id] != nil { return "exclamationmark.circle" }
        guard let track = entry.track else {
            return model.importedPlaylistSyncState.source(playlistID: playlistID, songID: entry.songID) == nil
                ? "cloud" : "checkmark.circle"
        }
        return model.cachedIDs.contains(track.id) ? "arrow.down.circle.fill" : "checkmark.circle"
    }
}

private struct ImportedAudioPicker: View {
    @ObservedObject var model: AppModel
    var playlistID: String
    var entry: ImportedPlaylistEntry
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Track] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Text(entry.title.isEmpty ? entry.songID : entry.title).font(.headline)
                Text("Choose the correct audio from the selected bot's recent replies.")
                    .font(.caption).foregroundStyle(.secondary)
                if isLoading { ProgressView() }
                if let error { Text(localizedUI(error)).foregroundStyle(.red) }
                ForEach(candidates) { track in
                    Button {
                        model.setImportedSource(track, playlistID: playlistID, entryID: entry.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(track.displayTitle)
                            Text("\(track.displayArtist) · \(DisplayFormat.duration(track.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose received audio")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                let accountID = model.activeAccountID
                do {
                    let tracks = try await model.importedAudioCandidates()
                    guard !Task.isCancelled, model.activeAccountID == accountID else { return }
                    // The same audio can have multiple messages in bot history.
                    var seen: Set<String> = []
                    candidates = tracks.filter { seen.insert($0.id).inserted }
                    if candidates.isEmpty { error = "No recent audio was found. Request the song from the bot first." }
                } catch { self.error = error.localizedDescription }
                isLoading = false
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
    }
}
