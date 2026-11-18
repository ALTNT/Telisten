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
                    Text("Import saves the song list. Telegram sync shares it with your other devices. Audio is requested only when you play a song.")
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
                Section("Playlist sync") {
                    Toggle("Sync using Telegram", isOn: $model.importedPlaylistSyncEnabled)
                    if model.isSyncingImportedPlaylists {
                        ProgressView("Syncing playlists…")
                    }
                    if let date = model.importedPlaylistSyncState.lastSyncedAt {
                        LabeledContent("Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !model.importedPlaylistSyncState.pending.isEmpty {
                        Text("\(model.importedPlaylistSyncState.pending.count) changes waiting to sync")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.importedPlaylistSyncError {
                        Text(localizedUI(error)).font(.caption).foregroundStyle(.red)
                    }
                    Button("Sync now") { Task { await model.syncImportedPlaylists() } }
                        .disabled(!model.importedPlaylistSyncEnabled || model.isSyncingImportedPlaylists || model.isDemo || model.activeAccountID == nil)
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
    @ObservedObject var model: AppModel
    var playlistID: String
    @State private var choosingSource: ImportedPlaylistEntry?

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
                    if model.resolvingImportedEntryID != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for music bot…")
                            Spacer()
                            Button("Cancel") { model.cancelImportedPlayback() }
                        }
                    }
                }
                Section {
                    ForEach(playlist.entries) { entry in
                        Button { model.playImportedEntry(entry.id, in: playlist.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: statusSymbol(entry))
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
                        .disabled(model.resolvingImportedEntryID != nil)
                        .contextMenu {
                            Link("Open original song", destination: entry.songURL)
                            Button("Choose received audio") { choosingSource = entry }
                            if entry.track != nil || model.importedPlaylistSyncState.source(playlistID: playlist.id, songID: entry.songID) != nil {
                                Button("Forget matched audio") {
                                    model.clearImportedSource(playlistID: playlist.id, entryID: entry.id)
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
        .sheet(item: $choosingSource) { entry in
            ImportedAudioPicker(model: model, playlistID: playlistID, entry: entry)
                .allowsApplicationTermination()
                .id(model.activeAccountID)
        }
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
