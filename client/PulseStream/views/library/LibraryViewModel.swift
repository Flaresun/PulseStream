import Foundation

/// Owns the user's playlists for the whole app, not just the Library tab —
/// the "Add to Playlist" sheet reaches it from Search, History and the player,
/// so a playlist created in one place shows up everywhere without a refetch.
@MainActor
@Observable
final class LibraryViewModel {
    var playlists: [PlaylistSummary] = []
    var isLoading = false
    var hasLoaded = false
    var lastError: String?

    private var inFlight: Task<Void, Never>?

    func load() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            isLoading = true
            defer {
                isLoading = false
                hasLoaded = true
                inFlight = nil
            }
            do {
                playlists = try await APIClient.shared.getPlaylists()
                lastError = nil
            } catch is CancellationError {
                // The view went away mid-request; keep what's on screen.
            } catch {
                lastError = error.localizedDescription
            }
        }
        inFlight = task
        await task.value
    }

    @discardableResult
    func createPlaylist(named name: String) async -> PlaylistSummary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let created = try await APIClient.shared.createPlaylist(name: trimmed)
            // Newest first, matching the server's ordering, so the new playlist
            // appears immediately without waiting for a refetch.
            playlists.insert(created, at: 0)
            lastError = nil
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deletePlaylist(id: Int) async {
        // Optimistic: put the row back if the server refuses, rather than
        // leaving the list showing something that still exists.
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let removed = playlists.remove(at: index)
        do {
            try await APIClient.shared.deletePlaylist(id: id)
            lastError = nil
        } catch {
            playlists.insert(removed, at: index)
            lastError = error.localizedDescription
        }
    }

    /// Adds `track` to a playlist. Returns false when it was already there —
    /// not a failure, just nothing to do.
    func add(track: Track, to playlistId: Int) async throws -> Bool {
        let response = try await APIClient.shared.addTrackToPlaylist(
            playlistId: playlistId, track: track
        )
        applyCount(response.trackCount, to: playlistId)
        return response.added
    }

    /// Keeps the cached summary in step with a change made on a detail screen,
    /// so the Library list doesn't show a stale track count.
    func applyCount(_ trackCount: Int, to playlistId: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let existing = playlists[index]
        playlists[index] = PlaylistSummary(
            id: existing.id,
            name: existing.name,
            trackCount: trackCount,
            thumbnailUrls: existing.thumbnailUrls,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt
        )
    }

    func applyRename(_ detail: PlaylistDetail) {
        guard let index = playlists.firstIndex(where: { $0.id == detail.id }) else { return }
        playlists[index] = detail.summary
    }
}
