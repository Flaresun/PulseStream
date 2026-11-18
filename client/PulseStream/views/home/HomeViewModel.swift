import Foundation

@MainActor
@Observable
final class HomeViewModel {
    var home: HomeResponse?
    var isLoading: Bool = false
    var hasLoaded: Bool = false
    var lastError: String?

    /// How stale a successful load has to be before coming back to the app
    /// refetches rather than showing what's already on screen.
    private static let staleAfter: TimeInterval = 5 * 60

    private var lastSuccessfulLoad: Date?
    private var inFlight: Task<Void, Never>?

    /// Loads Home, reusing an in-flight request rather than racing a second
    /// one — `.task`, pull-to-refresh and returning to the foreground can all
    /// ask at once, and two responses landing out of order used to be able to
    /// leave the older one on screen.
    func load() async {
        if let inFlight {
            await inFlight.value
            return
        }

        let task = Task { @MainActor in
            isLoading = true
            defer {
                isLoading = false
                hasLoaded = true
                inFlight = nil
            }
            do {
                home = try await APIClient.shared.getHome()
                lastError = nil
                lastSuccessfulLoad = Date()
            } catch is CancellationError {
                // Leave `home` alone: a cancelled load is the view going away,
                // not a failure worth showing the user.
            } catch {
                home = nil
                lastError = error.localizedDescription
            }
        }
        inFlight = task
        await task.value
    }

    /// Called when the app returns to the foreground. Home is rebuilt from
    /// listening history server-side, so it goes stale as you play tracks; it
    /// also needs a retry if the first attempt failed while the server or the
    /// network was still waking up.
    func loadIfStale() async {
        guard let lastSuccessfulLoad else {
            await load()
            return
        }
        guard Date().timeIntervalSince(lastSuccessfulLoad) > Self.staleAfter else { return }
        await load()
    }
}
