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

    // ytmusicapi only ever gives us a couple of small preset sizes (often
    // capped at 120x120), which look blurry once stretched to fill list rows
    // or the Now Playing artwork. Google's yt3.googleusercontent.com URLs
    // embed a live resize directive (`=wNNN-hNNN-...`) rather than pointing
    // at a fixed-size asset, so we can request a size matched to where the
    // image is actually displayed instead of upscaling the small default.
    func url(forSize size: Int) -> URL? {
        if let range = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            let rewritten = url.replacingCharacters(in: range, with: "=w\(size)-h\(size)")
            return URL(string: rewritten)
        }
        // Fixed-preset thumbnails (e.g. i.ytimg.com/vi/<id>/mqdefault.jpg) don't
        // support arbitrary sizes — fall back to the largest preset that's
        // guaranteed to exist for any video.
        if url.contains("ytimg.com"), let range = url.range(of: #"/\w*default\.jpg$"#, options: .regularExpression) {
            let rewritten = url.replacingCharacters(in: range, with: "/hqdefault.jpg")
            return URL(string: rewritten)
        }
        return URL(string: url)
    }
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

    // Sized for list rows and the mini player (up to ~144pt @3x)
    var primaryThumbnailURL: URL? {
        thumbnails?.first?.url(forSize: 160)
    }

    // Sized for the full Now Playing artwork (up to ~370pt @3x)
    var bestThumbnailURL: URL? {
        thumbnails?.last?.url(forSize: 1024)
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
    let album: SearchAlbum?
    let durationSeconds: Int?
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
            durationSeconds: durationSeconds ?? 0,
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
    let length: String?
    // Server field is "thumbnail" (singular), not "thumbnails"
    let thumbnail: [Thumbnail]

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: length.map(Self.parseDuration) ?? 0,
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
    let playlistId: String?
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

// MARK: - History Models

struct HistoryEntry: Codable, Identifiable, Hashable {
    let historyId: Int
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let durationSeconds: Int
    let thumbnailUrl: String?
    let playedAt: Double // epoch seconds

    var id: Int { historyId }

    var playedAtDate: Date {
        Date(timeIntervalSince1970: playedAt)
    }

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: durationSeconds,
            thumbnails: thumbnailUrl.map { [Thumbnail(url: $0, width: 0, height: 0)] }
        )
    }
}

struct RecordPlayRequest: Encodable {
    let playedDurationSeconds: Int
    let completionRate: Double
    let wasSkipped: Bool
}

// MARK: - Home Models

struct HomeSong: Codable, Identifiable, Hashable {
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let thumbnails: [Thumbnail]
    let durationSeconds: Int?

    var id: String { videoId }

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: durationSeconds ?? 0,
            thumbnails: thumbnails
        )
    }
}

struct HomeResponse: Codable {
    let speedDial: [HomeSong]
    let forgottenFavorites: [HomeSong]
    let quickPicks: [HomeSong]
    let explore: [HomeSong]
}
