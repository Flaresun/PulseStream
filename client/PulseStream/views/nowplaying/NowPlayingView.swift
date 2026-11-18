import SwiftUI

private enum CenterContent { case artwork, lyrics, queue }

struct NowPlayingView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var scrubPosition: Double? = nil
    @State private var centerContent: CenterContent = .artwork

    private var displayProgress: Double {
        scrubPosition ?? audioEngine.playbackProgress
    }

    // The engine's duration: track metadata where we have it, and the player
    // item's own duration only as a fallback for tracks that arrived without
    // any (search hits and watch-playlist entries often do). Metadata is
    // preferred because an HLS-proxied stream can misreport the song length.
    private var trackDuration: Double {
        audioEngine.duration
    }

    private var elapsedTime: String {
        formatTime(displayProgress * trackDuration)
    }

    private var endTime: String {
        formatTime(trackDuration)
    }

    // READY means the track finished caching to S3 and is being served from
    // our own storage, so it'll replay instantly and won't hit YouTube again.
    private var isCached: Bool {
        audioEngine.cacheStatus == .ready
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    switch centerContent {
                    case .artwork:
                        artworkView.transition(.opacity)
                    case .lyrics:
                        LyricsView().transition(.opacity)
                    case .queue:
                        QueueView().transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 20) {
                    trackInfo
                    scrubber
                    controls
                    contentToggles
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: audioEngine.currentTrack?.videoId) { _, _ in
                scrubPosition = nil
            }
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
        // Neon blue border once the track is fully cached in S3 — i.e. it's
        // streaming from our own storage and will replay instantly.
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.neonBlue, lineWidth: isCached ? 3 : 0)
                .shadow(color: Color.neonBlue.opacity(isCached ? 0.9 : 0), radius: 10)
                .shadow(color: Color.neonBlue.opacity(isCached ? 0.5 : 0), radius: 22)
        )
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .padding(.vertical, 24)
        .scaleEffect(audioEngine.isPlaying ? 1.0 : 0.92)
        .animation(.spring(duration: 0.4), value: audioEngine.isPlaying)
        .animation(.easeInOut(duration: 0.35), value: isCached)
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
                Text(endTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                audioEngine.toggleLoopCurrentTrack()
            } label: {
                Image(systemName: "repeat.1")
                    .font(.system(size: 20))
            }
            .tint(audioEngine.isLoopingCurrentTrack ? Color.neonBlue : Color.secondary)
            .accessibilityLabel(audioEngine.isLoopingCurrentTrack ? "Stop repeating" : "Repeat this song")

            Spacer(minLength: 0)

            Button {
                audioEngine.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
            }
            .tint(.primary)
            .disabled(!audioEngine.hasPreviousTrack)

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
            .tint(.primary)

            Button {
                audioEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
            }
            .tint(.primary)
            .disabled(!audioEngine.hasNextTrack && !audioEngine.isLoadingStream)

            Spacer(minLength: 0)

            // Balances the repeat button so the transport stays centred.
            Image(systemName: "repeat.1")
                .font(.system(size: 20))
                .hidden()
        }
    }

    private var contentToggles: some View {
        HStack(spacing: 12) {
            // Only disabled once the lookup has come back empty. It used to be
            // disabled whenever the browse ID was nil, which includes the
            // several seconds after a track loads while the watch-playlist
            // request (the only thing that carries that ID) is still in
            // flight — so tapping LYRICS early simply did nothing.
            togglePill(
                "LYRICS",
                active: centerContent == .lyrics,
                disabled: audioEngine.currentLyricsBrowseId == nil && !audioEngine.isResolvingLyrics
            ) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    centerContent = centerContent == .lyrics ? .artwork : .lyrics
                }
            }
            togglePill("QUEUE", active: centerContent == .queue) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    centerContent = centerContent == .queue ? .artwork : .queue
                }
            }
        }
    }

    private func togglePill(
        _ label: String,
        active: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Color.primary : Color.secondary.opacity(0.12))
                .foregroundStyle(active ? Color(uiColor: .systemBackground) : Color.secondary)
                .clipShape(Capsule())
        }
        .disabled(disabled)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
