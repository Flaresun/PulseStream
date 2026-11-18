import SwiftUI

struct LibraryView: View {
    @SwiftUI.Environment(LibraryViewModel.self) private var library
    @State private var isCreatePresented = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isCreatePresented = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                    }
                }
                .refreshable { await library.load() }
                .withMiniPlayer()
        }
        .task {
            guard !library.hasLoaded else { return }
            await library.load()
        }
        .sheet(isPresented: $isCreatePresented) {
            PlaylistNameSheet(title: "New Playlist", confirmLabel: "Create") { name in
                await library.createPlaylist(named: name)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.isLoading && !library.hasLoaded {
            ScrollView {
                ProgressView().padding(.top, 80).frame(maxWidth: .infinity)
            }
        } else if library.playlists.isEmpty {
            ScrollView {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "music.note.list")
                } description: {
                    Text(library.lastError ?? "Playlists you create will show up here.")
                } actions: {
                    Button("New Playlist") { isCreatePresented = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
                .frame(minHeight: 420)
            }
        } else {
            List {
                ForEach(library.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        PlaylistRowView(playlist: playlist)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await library.deletePlaylist(id: playlist.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: PlaylistSummary.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
        }
    }
}

// MARK: - Row

private struct PlaylistRowView: View {
    let playlist: PlaylistSummary

    var body: some View {
        HStack(spacing: 12) {
            PlaylistCoverView(thumbnailUrls: playlist.thumbnailUrls, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(playlist.trackCount == 1 ? "1 song" : "\(playlist.trackCount) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// A 2x2 collage of the playlist's first few covers, falling back to a single
/// cover or a placeholder glyph so every row is the same size either way.
struct PlaylistCoverView: View {
    let thumbnailUrls: [String]
    let size: CGFloat

    var body: some View {
        Group {
            if thumbnailUrls.isEmpty {
                placeholder
            } else if thumbnailUrls.count < 4 {
                cover(thumbnailUrls[0], side: size)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        cover(thumbnailUrls[0], side: size / 2)
                        cover(thumbnailUrls[1], side: size / 2)
                    }
                    HStack(spacing: 0) {
                        cover(thumbnailUrls[2], side: size / 2)
                        cover(thumbnailUrls[3], side: size / 2)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 12 : 6))
    }

    private func cover(_ url: String, side: CGFloat) -> some View {
        AsyncImage(url: Thumbnail(url: url, width: 0, height: 0).url(forSize: Int(side * 3))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        .frame(width: side, height: side)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note.list")
                .font(.system(size: size * 0.38))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Name sheet

/// Shared by "New Playlist" and "Rename", since the two differ only in wording.
struct PlaylistNameSheet: View {
    let title: String
    let confirmLabel: String
    var initialName: String = ""
    let onConfirm: (String) async -> Void

    @State private var name: String = ""
    @State private var isSubmitting = false
    @FocusState private var isFieldFocused: Bool
    @SwiftUI.Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($isFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(submit)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel, action: submit)
                        .disabled(trimmedName.isEmpty || isSubmitting)
                }
            }
            .onAppear {
                name = initialName
                isFieldFocused = true
            }
        }
        .presentationDetents([.height(180)])
    }

    private func submit() {
        guard !trimmedName.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await onConfirm(trimmedName)
            dismiss()
        }
    }
}
