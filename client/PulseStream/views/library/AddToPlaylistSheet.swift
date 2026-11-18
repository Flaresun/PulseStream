import SwiftUI

/// Picks a playlist to add `track` to, with inline creation for the common
/// case of "new playlist for this song". Reachable from Search, History, Home
/// and the player, so it owns no copy of the track — just the one passed in.
struct AddToPlaylistSheet: View {
    let track: Track

    @SwiftUI.Environment(LibraryViewModel.self) private var library
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var isCreatePresented = false
    @State private var busyPlaylistId: Int?
    @State private var status: Status?

    private enum Status: Equatable {
        case added(String)
        case alreadyPresent(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.isLoading && !library.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if library.playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No Playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Create one to start collecting songs.")
                    } actions: {
                        Button("New Playlist") { isCreatePresented = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    playlistList
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { trackHeader }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreatePresented = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard !library.hasLoaded else { return }
            await library.load()
        }
        .sheet(isPresented: $isCreatePresented) {
            PlaylistNameSheet(title: "New Playlist", confirmLabel: "Create") { name in
                // Creating one from here means "and put this song in it".
                guard let created = await library.createPlaylist(named: name) else { return }
                await add(to: created)
            }
        }
    }

    private var trackHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AsyncImage(url: track.primaryThumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    TitleWithExplicitBadge(
                        title: track.title,
                        isExplicit: track.isExplicit,
                        font: .subheadline,
                        weight: .semibold
                    )
                    Text(track.artists.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if let status {
                statusBar(status)
            }

            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    private func statusBar(_ status: Status) -> some View {
        let (text, icon, tint): (String, String, Color) = switch status {
        case .added(let name):
            ("Added to \(name)", "checkmark.circle.fill", .green)
        case .alreadyPresent(let name):
            ("Already in \(name)", "info.circle.fill", .secondary)
        case .failed(let message):
            (message, "exclamationmark.triangle.fill", .red)
        }

        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    private var playlistList: some View {
        List(library.playlists) { playlist in
            Button {
                Task { await add(to: playlist) }
            } label: {
                HStack(spacing: 12) {
                    PlaylistCoverView(thumbnailUrls: playlist.thumbnailUrls, size: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(.body)
                            .lineLimit(1)
                        Text(playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if busyPlaylistId == playlist.id {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busyPlaylistId != nil)
        }
        .listStyle(.plain)
    }

    private func add(to playlist: PlaylistSummary) async {
        busyPlaylistId = playlist.id
        defer { busyPlaylistId = nil }
        do {
            // `added == false` means it was already there. Playlists reject
            // duplicates, so that's a no-op worth saying out loud rather than
            // an error worth throwing.
            let added = try await library.add(track: track, to: playlist.id)
            status = added ? .added(playlist.name) : .alreadyPresent(playlist.name)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Entry point

/// Attaches a long-press "Add to Playlist" action to any song row.
///
/// The sheet is hosted here rather than on each call site so Search, History
/// and Home all get identical behaviour from one line.
struct AddToPlaylistMenu: ViewModifier {
    let track: Track
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    isPresented = true
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }
            .sheet(isPresented: $isPresented) {
                AddToPlaylistSheet(track: track)
            }
    }
}

extension View {
    func addToPlaylistAction(for track: Track) -> some View {
        modifier(AddToPlaylistMenu(track: track))
    }
}
