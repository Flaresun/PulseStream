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
        .onChange(of: audioEngine.elapsedSeconds) { _, _ in
            updateCurrentLine()
        }
    }

    // MARK: - Synced lyrics

    private func syncedLyricsView(_ songLyrics: SongLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack (not LazyVStack) so every row is in the layout tree and
                // scrollTo can target any line immediately, including on first appear.
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(songLyrics.lyrics.indices, id: \.self) { index in
                        let line = songLyrics.lyrics[index]
                        let isActive = index == currentLineIndex
                        Text(line.text)
                            .font(isActive ? .title2.weight(.heavy) : .body)
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                            .opacity(isActive ? 1.0 : 0.45)
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.2), value: currentLineIndex)
                    }
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
            .onAppear {
                guard currentLineIndex < songLyrics.lyrics.count else { return }
                proxy.scrollTo(songLyrics.lyrics[currentLineIndex].id, anchor: .center)
            }
        }
    }

    // MARK: - Helpers

    private func updateCurrentLine() {
        guard let lyrics else { return }
        // ytmusicapi returns start_time in milliseconds — read elapsed time
        // directly off the engine (not derived via playbackProgress * duration)
        // so lyric sync tracks the actual playback clock precisely.
        let currentMs = audioEngine.elapsedSeconds * 1000
        let newIndex = lyrics.lyrics.indices.last(where: {
            Double(lyrics.lyrics[$0].startTime) <= currentMs
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
