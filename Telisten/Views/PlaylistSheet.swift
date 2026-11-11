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
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(model.isSavingToPlaylist)
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
                Text("The original Telegram message will be forwarded.")
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
