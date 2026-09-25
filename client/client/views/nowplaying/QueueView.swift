import SwiftUI

struct QueueView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    var body: some View {
        let upcoming = Array(audioEngine.queue.dropFirst())
        if upcoming.isEmpty {
            ContentUnavailableView(
                "Queue Empty",
                systemImage: "list.bullet",
                description: Text("No upcoming songs.")
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { offset, track in
                        QueueRowView(track: track)
                            .onTapGesture {
                                // offset + 1 because we dropped the first (current) track
                                audioEngine.skipToQueueIndex(offset + 1)
                            }
                        if offset < upcoming.count - 1 {
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
        }
    }
}

private struct QueueRowView: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.primaryThumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artists.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatDuration(track.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
