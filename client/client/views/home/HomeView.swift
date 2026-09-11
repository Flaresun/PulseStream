import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Home",
                systemImage: "house.fill",
                description: Text("Coming soon.")
            )
            .navigationTitle("Home")
        }
    }
}
