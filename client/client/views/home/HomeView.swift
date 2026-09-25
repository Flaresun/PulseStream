import SwiftUI

struct HomeView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @State private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Home")
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
        } else if let home = viewModel.home {
            // Always show all four sections, even empty ones — an empty
            // section gets a placeholder rather than disappearing, so the
            // page layout doesn't shift around as history builds up.
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeCarouselSection(
                        title: "Speed Dial",
                        songs: home.speedDial,
                        pageSize: 9,
                        emptyMessage: "Play some songs to build your Speed Dial."
                    ) { page in
                        HomeGridPage(songs: page, columns: 3, onSelect: play)
                    }
                    HomeCarouselSection(
                        title: "Forgotten Favorites",
                        songs: home.forgottenFavorites,
                        pageSize: 1,
                        emptyMessage: "Songs you haven't played in a while will show up here."
                    ) { page in
                        if let song = page.first {
                            HomeRowCard(song: song, onSelect: play)
                                .padding(.horizontal)
                        }
                    }
                    HomeCarouselSection(
                        title: "Quick Picks",
                        songs: home.quickPicks,
                        pageSize: 4,
                        emptyMessage: "Songs you've played once or twice will show up here."
                    ) { page in
                        HomeGridPage(songs: page, columns: 4, onSelect: play)
                    }
                    HomeCarouselSection(
                        title: "Explore",
                        songs: home.explore,
                        pageSize: 4,
                        emptyMessage: "Play a few songs and we'll find more you might like."
                    ) { page in
                        HomeGridPage(songs: page, columns: 4, onSelect: play)
                    }
                }
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView(
                "Couldn't Load Home",
                systemImage: "house",
                description: Text("Pull to refresh and try again.")
            )
        }
    }

    private func play(_ song: HomeSong) {
        audioEngine.playTrack(song.toTrack())
    }
}

// MARK: - Carousel shell

/// A horizontally-paged carousel: `songs` is chunked into `pageSize`-sized
/// pages, and each page snaps fully into view as the user scrolls — used for
/// all four Home sections, each with a different page shape/size.
private struct HomeCarouselSection<PageContent: View>: View {
    let title: String
    let songs: [HomeSong]
    let pageSize: Int
    let emptyMessage: String
    @ViewBuilder var pageContent: (_ page: [HomeSong]) -> PageContent

    private var pages: [[HomeSong]] {
        guard pageSize > 0, !songs.isEmpty else { return [] }
        return stride(from: 0, to: songs.count, by: pageSize).map {
            Array(songs[$0..<min($0 + pageSize, songs.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal)

            if songs.isEmpty {
                HomeEmptyPage(message: emptyMessage)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            pageContent(page)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Shown in place of a section's carousel when it has no songs yet.
private struct HomeEmptyPage: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - Page content

/// One page of a grid-style section (Speed Dial's 3x3, Quick Picks/Explore's 4x1).
private struct HomeGridPage: View {
    let songs: [HomeSong]
    let columns: Int
    let onSelect: (HomeSong) -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(songs) { song in
                Button {
                    onSelect(song)
                } label: {
                    HomeSongCard(song: song)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

private struct HomeSongCard: View {
    let song: HomeSong

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: song.thumbnails.last?.url(forSize: 300)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(song.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(song.artists.map(\.name).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A single full-width row card — Forgotten Favorites' 1-song-per-page layout.
private struct HomeRowCard: View {
    let song: HomeSong
    let onSelect: (HomeSong) -> Void

    var body: some View {
        Button {
            onSelect(song)
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: song.thumbnails.last?.url(forSize: 300)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.2))
                }
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(song.artists.map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
