import SwiftUI

struct PlaylistDetailView: View {
    let playlist: PlaylistSummary

    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @SwiftUI.Environment(LibraryViewModel.self) private var library
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var detail: PlaylistDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isRenamePresented = false

    /// The header's name, falling back to the summary we were handed so the
    /// title is right from the first frame rather than after the fetch.
    private var name: String { detail?.name ?? playlist.name }

    private var tracks: [Track] { (detail?.tracks ?? []).map { $0.toTrack() } }

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isRenamePresented = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task {
                                await library.deletePlaylist(id: playlist.id)
                                dismiss()
                            }
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $isRenamePresented) {
                PlaylistNameSheet(
                    title: "Rename Playlist",
                    confirmLabel: "Save",
                    initialName: name
                ) { newName in
                    await rename(to: newName)
                }
            }
            .withMiniPlayer()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            ScrollView {
                ProgressView().padding(.top, 80).frame(maxWidth: .infinity)
            }
        } else if let loadError, detail == nil {
            ScrollView {
                ContentUnavailableView {
                    Label("Couldn't Load Playlist", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
                .frame(minHeight: 420)
            }
        } else {
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                }

                if let entries = detail?.tracks, !entries.isEmpty {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            // Start here and play on through the rest of the
                            // playlist, in order.
                            audioEngine.playCollection(tracks, named: name, startingAt: index)
                        } label: {
                            PlaylistTrackRow(entry: entry, index: index)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await remove(videoId: entry.videoId) }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No Songs Yet",
                            systemImage: "music.note",
                            description: Text("Add songs from Search, History or the player.")
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            PlaylistCoverView(
                thumbnailUrls: detail?.thumbnailUrls ?? playlist.thumbnailUrls,
                size: 160
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            Text(trackCountLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    audioEngine.playCollection(tracks, named: name)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    audioEngine.playCollection(tracks, named: name, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private var trackCountLabel: String {
        let count = detail?.tracks.count ?? playlist.trackCount
        return count == 1 ? "1 song" : "\(count) songs"
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await APIClient.shared.getPlaylist(id: playlist.id)
            detail = fetched
            loadError = nil
            // The Library list caches counts; keep it honest after an edit
            // made from this screen or another device.
            library.applyCount(fetched.tracks.count, to: fetched.id)
        } catch is CancellationError {
            // Navigated away mid-request.
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func rename(to newName: String) async {
        do {
            let updated = try await APIClient.shared.renamePlaylist(id: playlist.id, name: newName)
            detail = updated
            library.applyRename(updated)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func remove(videoId: String) async {
        // Drop it locally first so the row leaves under the swipe, and put it
        // back by refetching if the server disagrees.
        let previous = detail
        if var working = detail {
            working.tracks.removeAll { $0.videoId == videoId }
            detail = working
        }
        do {
            let response = try await APIClient.shared.removeTrackFromPlaylist(
                playlistId: playlist.id, videoId: videoId
            )
            library.applyCount(response.trackCount, to: playlist.id)
            await load()
        } catch {
            detail = previous
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct PlaylistTrackRow: View {
    let entry: PlaylistTrack
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)

            AsyncImage(url: entry.toTrack().primaryThumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                TitleWithExplicitBadge(title: entry.title, isExplicit: entry.isExplicit)
                Text(entry.artists.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if entry.durationSeconds > 0 {
                Text(formatDuration(entry.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
