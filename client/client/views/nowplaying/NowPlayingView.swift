import SwiftUI

struct NowPlayingView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @SwiftUI.Environment(\.dismiss) private var dismiss

    // Non-nil only while the user is actively dragging the scrubber
    @State private var scrubPosition: Double? = nil
    @State private var showLyrics = false

    private var displayProgress: Double {
        scrubPosition ?? audioEngine.playbackProgress
    }

    private var elapsedTime: String {
        formatTime(displayProgress * audioEngine.duration)
    }

    private var remainingTime: String {
        "-" + formatTime((1 - displayProgress) * audioEngine.duration)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Center content — artwork or lyrics, fills available space
                ZStack {
                    if showLyrics {
                        LyricsView()
                            .transition(.opacity)
                    } else {
                        artworkView
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Fixed controls section
                VStack(spacing: 20) {
                    trackInfo
                    scrubber
                    controls
                    lyricsToggle
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    private var artworkView: some View {
        AsyncImage(url: audioEngine.currentTrack?.bestThumbnailURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .padding(.vertical, 24)
        // Artwork shrinks slightly when paused — mimics Apple Music behaviour
        .scaleEffect(audioEngine.isPlaying ? 1.0 : 0.92)
        .animation(.spring(duration: 0.4), value: audioEngine.isPlaying)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(audioEngine.currentTrack?.title ?? "")
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Text(audioEngine.currentTrack?.artists.map(\.name).joined(separator: ", ") ?? "")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayProgress },
                    set: { scrubPosition = $0 }
                ),
                in: 0...1
            ) { editing in
                if !editing, let pos = scrubPosition {
                    audioEngine.seek(to: pos)
                    scrubPosition = nil
                }
            }
            .tint(.primary)

            HStack {
                Text(elapsedTime)
                Spacer()
                Text(remainingTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                // Seek to start; a proper "previous" history stack comes later
                audioEngine.seek(to: 0)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
            }

            Button {
                audioEngine.togglePlayPause()
            } label: {
                if audioEngine.isLoadingStream {
                    ProgressView()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: audioEngine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
            }

            Button {
                audioEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
            }
            .disabled(audioEngine.queue.count <= 1 && !audioEngine.isLoadingStream)
        }
        .tint(.primary)
    }

    private var lyricsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showLyrics.toggle()
            }
        } label: {
            Text("LYRICS")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(showLyrics ? Color.primary : Color.secondary.opacity(0.12))
                .foregroundStyle(showLyrics ? Color(uiColor: .systemBackground) : .secondary)
                .clipShape(Capsule())
        }
        .disabled(audioEngine.currentLyricsBrowseId == nil)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
