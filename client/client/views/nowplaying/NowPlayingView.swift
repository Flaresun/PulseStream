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

    // Static per-track duration from metadata — not audioEngine.duration, which
    // only reflects the currently loaded player item and can misreport the true
    // song length for HLS-proxied streams.
    private var trackDuration: Double {
        Double(audioEngine.currentTrack?.durationSeconds ?? 0)
    }

    private var elapsedTime: String {
        formatTime(displayProgress * trackDuration)
    }

    private var endTime: String {
        formatTime(trackDuration)
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
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .padding(.vertical, 24)
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
                Text(endTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                audioEngine.seek(to: 0)
                if !audioEngine.isPlaying { audioEngine.play() }
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

    private var contentToggles: some View {
        HStack(spacing: 12) {
            togglePill(
                "LYRICS",
                active: centerContent == .lyrics,
                disabled: audioEngine.currentLyricsBrowseId == nil
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
