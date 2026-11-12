import SwiftUI

struct PlaylistSheet: View {
    @ObservedObject var model: AppModel
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    FavoritesPlaylistButton {
                        model.addFavorites([track])
                        dismiss()
                    }
                    .disabled(model.isSavingToPlaylist)
                    if !model.playlists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("YOUR PLAYLISTS")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .tracking(0.8)
                            ForEach(model.playlists) { playlist in
                                playlistButton(playlist)
                            }
                        }
                    }
                    if let saveError {
                        Text(localizedUI(saveError))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Could not add song: \(saveError)")
                    }
                    newPlaylist
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(Color.telistenBackground)
            .navigationTitle("Add to…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(model.isSavingToPlaylist)
            .onChange(of: model.activeAccountID) { _ in dismiss() }
        }
        .frame(minWidth: 360, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            TrackArtwork(model: model, track: track, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Adding to a playlist forwards the original Telegram message.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func playlistButton(_ playlist: MusicChat) -> some View {
        Button {
            Task {
                saveError = nil
                if await model.save(track, to: playlist) {
                    dismiss()
                } else {
                    saveError = model.errorMessage ?? "Could not add this song to the playlist."
                }
            }
        } label: {
            HStack(spacing: 13) {
                ChatAvatar(model: model, chat: playlist, size: 34, fallbackSymbol: "music.note.list")
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if model.isSavingToPlaylist {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.plain)
        .disabled(model.isSavingToPlaylist)
    }

    private var newPlaylist: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NEW PLAYLIST")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Text("Creates a private Telegram channel in \(model.playlistFolderName). If the folder is full, the playlist stays available in Telisten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Divider() }
                    .onSubmit { create() }
                Button("Create", action: create)
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.telistenAccent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSavingToPlaylist)
            }
        }
        .padding(.top, 4)
    }

    private func create() {
        Task {
            saveError = nil
            if await model.createPlaylist(named: name, saving: track) {
                dismiss()
            } else {
                saveError = model.errorMessage ?? "Could not add this song to the playlist."
            }
        }
    }
}

struct BatchPlaylistSheet: View {
    @ObservedObject var model: AppModel
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remainingTracks: [Track]
    @State private var isSaving = false
    @State private var name = ""
    @State private var saveError: String?
    @State private var createdPlaylist: MusicChat?
    private let accountID: String?
    private let totalCount: Int

    init(model: AppModel, tracks: [Track], onSaved: @escaping (String) -> Void) {
        self.model = model
        self.onSaved = onSaved
        _remainingTracks = State(initialValue: tracks)
        accountID = model.activeAccountID
        totalCount = tracks.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(String(format: localizedUI("%lld selected"), Int64(remainingTracks.count)))
                        .font(.headline)
                    Text(remainingTracks.prefix(3).map(\.displayTitle).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if isSaving {
                        ProgressView(value: Double(totalCount - remainingTracks.count), total: Double(max(1, totalCount)))
                            .accessibilityLabel("Adding songs…")
                    }
                    if let saveError {
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }
                    FavoritesPlaylistButton {
                        guard model.activeAccountID == accountID else { return }
                        let tracks = remainingTracks
                        model.addFavorites(tracks)
                        remainingTracks.removeAll()
                        for track in tracks { onSaved(track.id) }
                        dismiss()
                    }
                    .disabled(isSaving || model.isSavingToPlaylist)
                    if !model.playlists.isEmpty {
                        Text("YOUR PLAYLISTS")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    ForEach(model.playlists) { playlist in
                        Button { save(to: playlist) } label: {
                            HStack(spacing: 12) {
                                ChatAvatar(model: model, chat: playlist, size: 34, fallbackSymbol: "music.note.list")
                                Text(playlist.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) { Divider() }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving || model.isSavingToPlaylist)
                    }
                    Text("NEW PLAYLIST")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("Playlist name", text: $name).onSubmit { create() }
                        Button(localizedUI(createdPlaylist?.title == name.trimmingCharacters(in: .whitespacesAndNewlines) ? "Retry" : "Create")) {
                            create()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .disabled(isSaving || model.isSavingToPlaylist)
                }
                .padding(20)
            }
            .background(Color.telistenBackground)
            .navigationTitle("Add to…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onChange(of: model.activeAccountID) { _ in dismiss() }
        }
        .frame(minWidth: 320, minHeight: 440)
    }

    private func save(to playlist: MusicChat) {
        guard !isSaving, model.activeAccountID == accountID else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            await saveRemaining(to: playlist)
        }
    }

    private func create() {
        guard !isSaving, model.activeAccountID == accountID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            let playlist: MusicChat?
            if let createdPlaylist, createdPlaylist.title == trimmed {
                playlist = createdPlaylist
            } else {
                playlist = await model.createPlaylist(named: trimmed)
                createdPlaylist = playlist
            }
            guard model.activeAccountID == accountID else { return }
            guard let playlist else {
                saveError = localizedUI(model.errorMessage ?? "Could not add this song to the playlist.")
                model.errorMessage = nil
                return
            }
            await saveRemaining(to: playlist)
        }
    }

    private func saveRemaining(to playlist: MusicChat) async {
        saveError = nil
        let failure = await model.saveTracks(remainingTracks, to: playlist) { id in
            remainingTracks.removeAll { $0.id == id }
            onSaved(id)
        }
        guard model.activeAccountID == accountID else { return }
        if remainingTracks.isEmpty {
            dismiss()
        } else {
            saveError = String(format: localizedUI("%lld songs could not be added. Retry the remaining songs."), Int64(remainingTracks.count))
            if let failure { saveError = "\(saveError ?? "")\n\(localizedUI(failure))" }
        }
    }
}

private struct FavoritesPlaylistButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .frame(width: 34, height: 34)
                    .background(Color.red.opacity(0.1), in: Circle())
                Text("Favorites").foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.plain)
    }
}
