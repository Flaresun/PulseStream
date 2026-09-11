import SwiftUI

struct MiniPlayerBar: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @State private var isNowPlayingPresented = false

    var body: some View {
        HStack(spacing: 12) {
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
                        Text(audioEngine.currentTrack?.title ?? "")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Text(audioEngine.currentTrack?.artists.first?.name ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Playback controls — independent of the expand tap target
            if audioEngine.isLoadingStream {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .tint(.primary)
            }

            Button {
                audioEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .tint(.primary)
            .disabled(audioEngine.queue.count <= 1)
        }
        .padding(.horizontal)
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
