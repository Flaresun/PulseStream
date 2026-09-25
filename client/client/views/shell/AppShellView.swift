import SwiftUI

struct AppShellView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    var body: some View {
        TabView {
            HomeView()
                .withMiniPlayer()
                .tabItem { Label("Home", systemImage: "house.fill") }

            SearchView()
                .withMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            HistoryView()
                .withMiniPlayer()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            LibraryView()
                .withMiniPlayer()
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
    }
}

private extension View {
    // Applying safeAreaInset on each tab's content (not on the TabView itself) ensures
    // the mini player sits above the tab bar rather than overlapping it.
    func withMiniPlayer() -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBarHost()
        }
    }
}

// Separate host so the environment lookup is scoped to this view, not the modifier closure.
private struct MiniPlayerBarHost: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    var body: some View {
        if audioEngine.currentTrack != nil {
            MiniPlayerBar()
        }
    }
}
