import Foundation

@MainActor
@Observable
final class HistoryViewModel {
    var entries: [HistoryEntry] = []
    var isLoading: Bool = false
    var hasLoaded: Bool = false

    func load() async {
        isLoading = true
        do {
            entries = try await APIClient.shared.getHistory()
        } catch {
            entries = []
        }
        isLoading = false
        hasLoaded = true
    }
}
