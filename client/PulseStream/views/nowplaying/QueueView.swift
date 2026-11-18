import SwiftUI

struct QueueView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    /// Already-played tracks, most recent first, paired with their absolute
    /// position in the queue so tapping one jumps straight back to it.
    private var played: [(index: Int, track: Track)] {
        guard audioEngine.currentIndex > 0 else { return [] }
        return (0..<audioEngine.currentIndex)
            .reversed()
            .map { ($0, audioEngine.queue[$0]) }
    }

    private var upcoming: [(index: Int, track: Track)] {
        let start = audioEngine.currentIndex + 1
        guard start < audioEngine.queue.count else { return [] }
        return (start..<audioEngine.queue.count).map { ($0, audioEngine.queue[$0]) }
    }

    var body: some View {
        if played.isEmpty && upcoming.isEmpty {
            ContentUnavailableView(
                "Queue Empty",
                systemImage: "list.bullet",
                description: Text("No upcoming songs.")
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    section("UP NEXT", entries: upcoming)
                    section("PREVIOUSLY PLAYED", entries: played)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, entries: [(index: Int, track: Track)]) -> some View {
        if !entries.isEmpty {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(Array(entries.enumerated()), id: \.element.index) { offset, entry in
                QueueRowView(track: entry.track)
                    .onTapGesture {
                        audioEngine.skipToQueueIndex(entry.index)
                    }
                if offset < entries.count - 1 {
                    Divider().padding(.leading, 72)
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

            if track.durationSeconds > 0 {
                Text(formatDuration(track.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
