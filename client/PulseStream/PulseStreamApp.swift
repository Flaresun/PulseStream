import SwiftUI

@main
struct PulseStreamApp: App {
    @State private var audioEngine = AudioEngine()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(audioEngine)
        }
    }
}
