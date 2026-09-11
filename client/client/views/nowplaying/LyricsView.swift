import SwiftUI

struct LyricsView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    @State private var lyrics: SongLyrics? = nil
    @State private var isLoading = false
    @State private var currentLineIndex = 0
    // Tracks which browse ID we already fetched so we don't re-fetch on every re-render
    @State private var fetchedBrowseId: String? = nil

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics {
                syncedLyricsView(lyrics)
            } else {
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "music.note",
                    description: Text("Lyrics aren't available for this song.")
                )
            }
        }
        .task {
            await fetchLyrics(browseId: audioEngine.currentLyricsBrowseId)
        }
        .onChange(of: audioEngine.currentLyricsBrowseId) { _, newId in
            lyrics = nil
            currentLineIndex = 0
            fetchedBrowseId = nil
            Task { await fetchLyrics(browseId: newId) }
        }
        .onChange(of: audioEngine.playbackProgress) { _, _ in
            updateCurrentLine()
        }
    }

    // MARK: - Synced lyrics

    private func syncedLyricsView(_ songLyrics: SongLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(songLyrics.lyrics.enumerated()), id: \.element.id) { index, line in
                        Text(line.text)
                            .font(index == currentLineIndex ? .title3.weight(.bold) : .body)
                            .foregroundStyle(index == currentLineIndex ? .primary : .secondary)
                            .opacity(index == currentLineIndex ? 1.0 : 0.45)
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.2), value: currentLineIndex)
                    }
                    // Bottom padding so the last line can scroll to center
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal)
                .padding(.top, 16)
            }
            .onChange(of: currentLineIndex) { _, newIndex in
                guard newIndex < songLyrics.lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(songLyrics.lyrics[newIndex].id, anchor: .center)
                }
            }
            // Scroll to current position without animation when lyrics first load
            .onAppear {
                guard currentLineIndex < songLyrics.lyrics.count else { return }
                proxy.scrollTo(songLyrics.lyrics[currentLineIndex].id, anchor: .center)
            }
        }
    }

    // MARK: - Helpers

    private func updateCurrentLine() {
        guard let lyrics else { return }
        let currentTimeMs = audioEngine.playbackProgress * audioEngine.duration * 1000
        let newIndex = lyrics.lyrics.indices.last(where: {
            Double(lyrics.lyrics[$0].startTime) <= currentTimeMs
        }) ?? 0
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    private func fetchLyrics(browseId: String?) async {
        guard let browseId, browseId != fetchedBrowseId else { return }
        isLoading = true
        fetchedBrowseId = browseId
        do {
            let result = try await APIClient.shared.getLyrics(lyricsId: browseId)
            lyrics = result
            updateCurrentLine()
        } catch {
            lyrics = nil
        }
        isLoading = false
    }
}
