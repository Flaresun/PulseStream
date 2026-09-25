import Foundation

@MainActor
@Observable
final class HomeViewModel {
    var home: HomeResponse?
    var isLoading: Bool = false
    var hasLoaded: Bool = false

    func load() async {
        isLoading = true
        do {
            home = try await APIClient.shared.getHome()
        } catch {
            home = nil
        }
        isLoading = false
        hasLoaded = true
    }
}
