import Foundation

enum Environment {
    static nonisolated var SERVER_URL: URL {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SERVER_URL") as? String,
              let url = URL(string: urlString) else {
            fatalError("SERVER_URL missing from Info.plist")
        }
        return url
    }
}
