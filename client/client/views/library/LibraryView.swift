import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Library",
                systemImage: "music.note.list",
                description: Text("Coming soon.")
            )
            .navigationTitle("Library")
        }
    }
}
