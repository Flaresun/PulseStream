import SwiftUI

struct SearchView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine
    @State private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(text: $viewModel.query, prompt: "Songs, artists, albums")
                .searchSuggestions {
                    ForEach(viewModel.suggestions, id: \.self) { suggestion in
                        Label(suggestion, systemImage: "magnifyingglass")
                            .searchCompletion(suggestion)
                    }
                }
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.onQueryChanged()
                }
                .onSubmit(of: .search) {
                    Task { await viewModel.search() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.results.isEmpty {
            resultsList
        } else if viewModel.hasSearched {
            ContentUnavailableView(
                "No Results",
                systemImage: "music.note",
                description: Text("Try a different search term.")
            )
        } else {
            ContentUnavailableView(
                "Find Your Music",
                systemImage: "magnifyingglass",
                description: Text("Search for songs, artists, and albums.")
            )
        }
    }

    private var resultsList: some View {
        List(viewModel.results) { song in
            Button {
                audioEngine.playTrack(song.toTrack())
            } label: {
                SongRowView(song: song)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
    }
}
