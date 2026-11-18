import SwiftUI

struct MiniPlayerBar: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @State private var isNowPlayingPresented = false

    var body: some View {
        HStack(spacing: 4) {
            // Tapping the track info expands to Now Playing
            Button {
                isNowPlayingPresented = true
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: audioEngine.currentTrack?.primaryThumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        TitleWithExplicitBadge(
                            title: audioEngine.currentTrack?.title ?? "",
                            isExplicit: audioEngine.currentTrack?.isExplicit,
                            font: .footnote,
                            weight: .semibold
                        )
                        Text(audioEngine.currentTrack?.artists.first?.name ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                audioEngine.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.footnote)
                    .frame(width: 38, height: 44)
            }
            .tint(.primary)
            .disabled(!audioEngine.hasPreviousTrack)

            // Playback controls — independent of the expand tap target
            if audioEngine.isLoadingStream {
                ProgressView()
                    .frame(width: 40, height: 44)
            } else {
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 44)
                }
                .tint(.primary)
            }

            Button {
                audioEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.footnote)
                    .frame(width: 38, height: 44)
            }
            .tint(.primary)
            .disabled(!audioEngine.hasNextTrack)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
        }
    }
}
