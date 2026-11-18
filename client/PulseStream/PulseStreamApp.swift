import SwiftUI

@main
struct PulseStreamApp: App {
    @State private var audioEngine = AudioEngine()
    // App-level so a playlist created from the "Add to Playlist" sheet in
    // Search or the player is immediately visible in the Library tab.
    @State private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(audioEngine)
                .environment(library)
        }
    }
}
