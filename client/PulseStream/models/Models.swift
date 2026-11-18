import Foundation
import SwiftUI

// MARK: - Enums
enum S3Status: String, Codable {
    case notCached = "NOT_CACHED"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
}

// MARK: - Shared Types
struct Thumbnail: nonisolated Codable, Hashable {
    let url: String
    let width: Int
    let height: Int

    // ytmusicapi only ever gives us a couple of small preset sizes (often
    // capped at 120x120), which look blurry once stretched to fill list rows
    // or the Now Playing artwork. Google's yt3.googleusercontent.com URLs
    // embed a live resize directive (`=wNNN-hNNN-...`) rather than pointing
    // at a fixed-size asset, so we can request a size matched to where the
    // image is actually displayed instead of upscaling the small default.
    nonisolated func url(forSize size: Int) -> URL? {
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
struct Artist: nonisolated Codable, Identifiable, Hashable {
    let name: String
    let browseId: String?
    // Stable ID: prefer browseId, fall back to name so Identifiable is consistent
    var id: String { browseId ?? name }
}

struct Track: nonisolated Codable, Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artists: [Artist]
    let durationSeconds: Int
    let thumbnails: [Thumbnail]?
    // Optional on the wire, and defaulted in the memberwise init, so a
    // response from a server that predates the field still decodes and every
    // existing construction site keeps compiling. Swift's synthesised
    // Decodable ignores default values for non-optional properties, so an
    // Optional is what actually buys the backward compatibility here.
    var isExplicit: Bool? = nil

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

struct SearchArtist: nonisolated Codable, Hashable {
    let name: String
    let id: String?

    func toArtist() -> Artist {
        Artist(name: name, browseId: id)
    }
}

struct SearchAlbum: nonisolated Codable, Hashable {
    let name: String
    let id: String
}

struct SearchSong: nonisolated Codable, Identifiable, Hashable {
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
            thumbnails: thumbnails,
            isExplicit: isExplicit
        )
    }
}

// MARK: - Watch Playlist / Next Songs Models

struct NextSongTrack: nonisolated Codable, Identifiable, Hashable {
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

    nonisolated private static func parseDuration(_ duration: String) -> Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}

struct PlaylistTracksResponse: nonisolated Codable {
    let tracks: [NextSongTrack]
    let playlistId: String?
    // Browse ID passed to /songs/lyrics/{id} — not actual lyrics text
    let lyrics: String?
}

// MARK: - Lyrics Models

struct LyricLine: nonisolated Codable, Identifiable, Hashable {
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

struct SongLyrics: nonisolated Codable {
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

struct ClientArtist: nonisolated Codable {
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
    let isExplicit: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case durationSeconds = "duration_seconds"
        case thumbnailUrl = "thumbnail_url"
        case artists
        case isExplicit = "is_explicit"
    }
}

// MARK: - History Models

struct HistoryEntry: nonisolated Codable, Identifiable, Hashable {
    let historyId: Int
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let durationSeconds: Int
    let thumbnailUrl: String?
    var isExplicit: Bool? = nil
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
            thumbnails: thumbnailUrl.map { [Thumbnail(url: $0, width: 0, height: 0)] },
            isExplicit: isExplicit
        )
    }
}

struct RecordPlayRequest: nonisolated Encodable {
    let playedDurationSeconds: Int
    let completionRate: Double
    let wasSkipped: Bool
}

// MARK: - Home Models

struct HomeSong: nonisolated Codable, Identifiable, Hashable {
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let thumbnails: [Thumbnail]
    let durationSeconds: Int?
    var isExplicit: Bool? = nil

    var id: String { videoId }

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: durationSeconds ?? 0,
            thumbnails: thumbnails,
            isExplicit: isExplicit
        )
    }
}

struct HomeResponse: nonisolated Codable {
    let speedDial: [HomeSong]
    let forgottenFavorites: [HomeSong]
    let quickPicks: [HomeSong]
    let explore: [HomeSong]
}

// MARK: - Theme

extension Color {
    /// Used to mark tracks that are fully cached in S3.
    static let neonBlue = Color(red: 0.25, green: 0.78, blue: 1.0)
}

// MARK: - Library Models

/// A playlist as it appears in the library list — contents not included.
struct PlaylistSummary: nonisolated Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let trackCount: Int
    /// Up to four covers, in playlist order, for the list artwork.
    var thumbnailUrls: [String] = []
    let createdAt: Double
    let updatedAt: Double
}

/// One entry in a playlist. `position` is the server's ordinal: sparse, not a
/// dense 0..n-1 range, so removing a track never renumbers the others.
struct PlaylistTrack: nonisolated Codable, Identifiable, Hashable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artists: [SearchArtist]
    let durationSeconds: Int
    let thumbnailUrl: String?
    var isExplicit: Bool? = nil
    let position: Int

    func toTrack() -> Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists.map { $0.toArtist() },
            durationSeconds: durationSeconds,
            thumbnails: thumbnailUrl.map { [Thumbnail(url: $0, width: 0, height: 0)] },
            isExplicit: isExplicit
        )
    }
}

struct PlaylistDetail: nonisolated Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let trackCount: Int
    var thumbnailUrls: [String] = []
    let createdAt: Double
    let updatedAt: Double
    var tracks: [PlaylistTrack] = []

    var summary: PlaylistSummary {
        PlaylistSummary(
            id: id,
            name: name,
            trackCount: trackCount,
            thumbnailUrls: thumbnailUrls,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct PlaylistNameRequest: nonisolated Encodable {
    let name: String
}

/// Carries enough metadata for the server to register a song it may never have
/// seen — a track can be added to a playlist without ever having been played,
/// so we can't assume /stream/resolve has run for it.
struct AddPlaylistTrackRequest: nonisolated Encodable {
    let videoId: String
    let title: String
    let durationSeconds: Int
    let thumbnailUrl: String?
    let isExplicit: Bool
    let artists: [PlaylistArtistPayload]

    init(track: Track) {
        self.videoId = track.videoId
        self.title = track.title
        self.durationSeconds = track.durationSeconds
        self.thumbnailUrl = track.thumbnails?.first?.url
        self.isExplicit = track.isExplicit ?? false
        self.artists = track.artists.map {
            PlaylistArtistPayload(name: $0.name, id: $0.browseId)
        }
    }
}

struct PlaylistArtistPayload: nonisolated Encodable {
    let name: String
    let id: String?
}

/// `added` is false when the song was already in the playlist. That isn't an
/// error — playlists reject duplicates, so asking twice is a no-op.
struct AddPlaylistTrackResponse: nonisolated Codable {
    let added: Bool
    let trackCount: Int
}
