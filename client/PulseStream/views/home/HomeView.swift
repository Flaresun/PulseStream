import SwiftUI

struct HomeView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            // Every state below is wrapped in a ScrollView so pull-to-refresh
            // is available even when there's nothing to show — the failure
            // state used to be a bare ContentUnavailableView with nothing
            // scrollable in it, leaving no way to retry but switching tabs.
            content
                .refreshable { await viewModel.load() }
                .navigationTitle("Home")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        InstallExpiryBadge()
                    }
                }
                .withMiniPlayer()
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background doesn't re-run `.task`, which is
            // why Home could sit empty until the user bounced off to another
            // tab and back.
            guard phase == .active else { return }
            Task { await viewModel.loadIfStale() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            ScrollView {
                ProgressView()
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
            }
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
                .padding(.top, 12)
                // Clears the mini player's rounded card even when the safe-area
                // inset hasn't been applied yet (it appears mid-scroll, the
                // moment a track starts), so the last row of Explore is always
                // tappable rather than sitting under the bar.
                .padding(.bottom, 28)
            }
        } else {
            ScrollView {
                ContentUnavailableView {
                    Label("Couldn't Load Home", systemImage: "house")
                } description: {
                    Text(viewModel.lastError ?? "Pull down to refresh and try again.")
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
                // ContentUnavailableView sizes to its content; this keeps the
                // scroll view tall enough to actually pull on.
                .frame(minHeight: 420)
            }
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
                .addToPlaylistAction(for: song.toTrack())
            }
        }
        .padding(.horizontal)
    }
}

private struct HomeSongCard: View {
    let song: HomeSong

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The square comes from a Color.clear spacer rather than an
            // aspectRatio on the AsyncImage itself: a `.fill` image reports its
            // own (non-square) ideal size, which widened the grid cell and let
            // artwork and titles spill over their neighbours. Sizing the
            // container first and overlaying the image pins every cell square.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: song.thumbnails.last?.url(forSize: 300)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            TitleWithExplicitBadge(
                title: song.title,
                isExplicit: song.isExplicit,
                font: .caption,
                weight: .medium
            )
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
                    TitleWithExplicitBadge(
                        title: song.title,
                        isExplicit: song.isExplicit,
                        font: .body,
                        weight: .semibold
                    )
                    Text(song.artists.map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .addToPlaylistAction(for: song.toTrack())
    }
}
