import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    var suggestions: [String] = []
    var results: [SearchSong] = []
    var isSearching: Bool = false
    var hasSearched: Bool = false

    private var suggestionTask: Task<Void, Never>?

    func onQueryChanged() {
        suggestionTask?.cancel()
        suggestions = []

        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let fetched = try await APIClient.shared.getSearchSuggestions(query: query)
                if !Task.isCancelled {
                    suggestions = fetched
                }
            } catch {}
        }
    }

    func search() async {
        guard !query.isEmpty else { return }
        suggestionTask?.cancel()
        suggestions = []
        isSearching = true
        do {
            results = try await APIClient.shared.searchSongs(query: query)
        } catch {
            results = []
        }
        isSearching = false
        hasSearched = true
    }
}
