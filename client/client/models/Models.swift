import Foundation

// MARK: - Enums
enum S3Status: String, Codable {
    case notCached = "NOT_CACHED"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
}

// MARK: - Shared Types
struct Thumbnail: Codable, Hashable {
    let url: String
    let width: Int
    let height: Int
}

// MARK: - Domain Models (Canonical playback model used by AudioEngine)
struct Artist: Codable, Identifiable, Hashable {
    let name: String
    let browseId: String?
    // Stable ID: prefer browseId, fall back to name so Identifiable is consistent
    var id: String { browseId ?? name }
}

struct Track: Codable, Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artists: [Artist]
    let durationSeconds: Int
    let thumbnails: [Thumbnail]?

    // Smallest thumbnail — suitable for list rows and mini player
    var primaryThumbnailURL: URL? {
        guard let urlString = thumbnails?.first?.url else { return nil }
        return URL(string: urlString)
    }

    // Largest thumbnail — suitable for the full Now Playing screen
    var bestThumbnailURL: URL? {
        guard let urlString = thumbnails?.last?.url else { return nil }
        return URL(string: urlString)
    }
}

// MARK: - Search Models

struct SearchArtist: Codable, Hashable {
    let name: String
    let id: String?

    func toArtist() -> Artist {
        Artist(name: name, browseId: id)
    }
}

struct SearchAlbum: Codable, Hashable {
    let name: String
    let id: String
}

struct SearchSong: Codable, Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let album: SearchAlbum
    let durationSeconds: Int
    let thumbnails: [Thumbnail]
    let isExplicit: Bool

    enum CodingKeys: String, CodingKey {
        case videoId, title, artists, album, thumbnails, isExplicit
        case durationSeconds = "duration_seconds"
    }

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: durationSeconds,
            thumbnails: thumbnails
        )
    }
}

// MARK: - Watch Playlist / Next Songs Models

struct NextSongTrack: Codable, Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    // Server field is "length" (e.g. "3:45"), not duration_seconds
    let length: String
    // Server field is "thumbnail" (singular), not "thumbnails"
    let thumbnail: [Thumbnail]

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: Self.parseDuration(length),
            thumbnails: thumbnail
        )
    }

    private static func parseDuration(_ duration: String) -> Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}

struct PlaylistTracksResponse: Codable {
    let tracks: [NextSongTrack]
    let playlistId: String
    // Browse ID passed to /songs/lyrics/{id} — not actual lyrics text
    let lyrics: String?
}

// MARK: - Lyrics Models

struct LyricLine: Codable, Identifiable, Hashable {
    let id: Int
    let text: String
    let startTime: Int  // milliseconds
    let endTime: Int    // milliseconds

    enum CodingKeys: String, CodingKey {
        case id, text
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

struct SongLyrics: Codable {
    let lyrics: [LyricLine]
    let source: String
    let hasTimestamps: Bool
}

// MARK: - Stream API Models

struct StreamResponse: nonisolated Codable {
    let source: String
    let s3Status: S3Status
    let streamUrl: String

    enum CodingKeys: String, CodingKey {
        case source
        case s3Status = "s3_status"
        case streamUrl = "stream_url"
    }
}

struct ClientArtist: Codable {
    let name: String
    let browseId: String

    enum CodingKeys: String, CodingKey {
        case name
        case browseId = "browse_id"
    }
}

struct ResolveStreamRequest: nonisolated Codable {
    let title: String
    let durationSeconds: Int
    let thumbnailUrl: String
    let artists: [ClientArtist]

    enum CodingKeys: String, CodingKey {
        case title
        case durationSeconds = "duration_seconds"
        case thumbnailUrl = "thumbnail_url"
        case artists
    }
}
