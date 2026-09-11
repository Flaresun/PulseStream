import SwiftUI

@main
struct clientApp: App {
    @State private var audioEngine = AudioEngine()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(audioEngine)
        }
    }
}
