import SwiftUI

struct AppShellView: View {
    @SwiftUI.Environment(AudioEngine.self) private var audioEngine

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audioEngine.currentTrack != nil {
                MiniPlayerBar()
            }
        }
    }
}
