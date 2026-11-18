import SwiftUI

struct AppShellView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
    }
}

extension View {
    /// Docks the mini player above the tab bar and reserves room for it.
    ///
    /// Apply this to a tab's *scrollable content, inside* its NavigationStack —
    /// not to the NavigationStack from outside. Applied outside, the inset is
    /// taken out of the navigation container's frame and never reaches the
    /// scroll view's content inset, so the bar ends up covering the bottom of
    /// the page (the last row of Home's Explore section, most visibly).
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
