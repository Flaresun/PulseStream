import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Int)
    case decodingFailed(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The URL provided was invalid."
        case .requestFailed(let code): return "Server returned an error code: \(code)."
        case .decodingFailed(let error): return "Failed to parse server response: \(error.localizedDescription)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    private let baseURL = Environment.SERVER_URL

    private init() {}

    // MARK: - Generic GET

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        print(url)
        let (data, response) = try await perform(URLRequest(url: url))
        return try decode(T.self, from: data, response: response)
    }

    // MARK: - Search

    func searchSongs(query: String) async throws -> [SearchSong] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return try await get("/songs/songs/\(encoded)")
    }

    func getSearchSuggestions(query: String) async throws -> [String] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return try await get("/songs/suggestions/\(encoded)")
    }

    // MARK: - Queue

    func getNextSongs(videoId: String) async throws -> PlaylistTracksResponse {
        return try await get("/songs/nextSongs/\(videoId)")
    }

    // MARK: - Lyrics

    func getLyrics(lyricsId: String) async throws -> SongLyrics {
        return try await get("/songs/lyrics/\(lyricsId)")
    }

    // MARK: - Stream

    func resolveStream(for track: Track) async throws -> StreamResponse {
        guard let url = URL(string: "\(baseURL)/stream/resolve/\(track.videoId)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let clientArtists = track.artists.map {
            ClientArtist(name: $0.name, browseId: $0.browseId ?? "")
        }
        let payload = ResolveStreamRequest(
            title: track.title,
            durationSeconds: track.durationSeconds,
            thumbnailUrl: track.thumbnails?.first?.url ?? "",
            artists: clientArtists
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw APIError.decodingFailed(error)
        }

        let (data, response) = try await perform(request)
        return try decode(StreamResponse.self, from: data, response: response)
    }

    // MARK: - Shared Helpers

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(NSError(domain: "InvalidResponse", code: -1))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}
