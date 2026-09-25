import SwiftUI

struct HistoryView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
        }
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.entries.isEmpty {
            ContentUnavailableView(
                "No History Yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Songs you listen to will show up here.")
            )
        } else {
            List(viewModel.entries) { entry in
                Button {
                    audioEngine.playTrack(entry.toTrack())
                } label: {
                    HistoryRowView(entry: entry)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            .listStyle(.plain)
        }
    }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.toTrack().primaryThumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.artists.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(entry.playedAtDate, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
