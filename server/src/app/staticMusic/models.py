from dataclasses import dataclass
from typing import Optional, List, Dict, Any
from pydantic import BaseModel


class Album(BaseModel):
    name: str
    id: str


class Artist(BaseModel):
    name: str
    id: Optional[str] = None


class Thumbnail(BaseModel):
    url: str
    width: int
    height: int


class Song(BaseModel):
    category: str
    resultType: str
    title: str
    album: Optional[Album] = None
    inLibrary: bool
    pinnedToListenAgain: bool
    videoId: str
    videoType: Optional[str] = None
    duration: Optional[str] = None
    artists: List[Artist] = []
    duration_seconds: Optional[int] = None
    views: Optional[str] = None
    isExplicit: bool
    thumbnails: List[Thumbnail]
    year: Optional[int] = None


class ArtistResult(BaseModel):
    category: str
    resultType: str
    artist: str
    browseId: str
    thumbnails: List[Thumbnail]
    shuffleId: Optional[str] = None
    radioId: Optional[str] = None


# Albums
class DescriptionRun(BaseModel):
    text: str
    url: Optional[str] = None


class FeedbackTokens(BaseModel):
    add: Optional[str] = None
    remove: Optional[str] = None


class Track(BaseModel):
    videoId: str
    title: str
    artists: Optional[List[Artist]] = None
    album: str
    likeStatus: str
    inLibrary: bool
    pinnedToListenAgain: bool
    feedbackTokens: FeedbackTokens
    isAvailable: bool
    isExplicit: bool
    videoType: str
    views: str
    trackNumber: int
    duration: str
    duration_seconds: int
    creditsBrowseId: Optional[str] = None
    thumbnails: Optional[List[Thumbnail]] = None
    communityVoteStatus: Optional[str] = None


class AlbumVersion(BaseModel):
    title: str
    artists: List[Artist]
    browseId: str
    audioPlaylistId: Optional[str] = None
    thumbnails: List[Thumbnail]
    isExplicit: bool
    type: Optional[str] = None


class AlbumDetails(BaseModel):
    title: str
    type: str
    thumbnails: List[Thumbnail]
    isExplicit: bool
    description: str
    descriptionRuns: List[DescriptionRun]
    year: Optional[str] = None
    artists: Optional[List[Artist]] = None
    trackCount: Optional[int] = None
    duration: str
    audioPlaylistId: Optional[str] = None
    likeStatus: str
    tracks: List[Track]
    duration_seconds: int
    other_versions: Optional[List[AlbumVersion]] = None


# Up Next Queue
class AlbumRef(BaseModel):
    name: str
    id: str


class TrackResult(BaseModel):
    videoId: str
    title: str
    length: Optional[str] = None
    thumbnail: List[Thumbnail]
    videoType: Optional[str] = None
    inLibrary: bool
    pinnedToListenAgain: bool
    artists: List[Artist] = []
    album: Optional[AlbumRef] = None
    year: Optional[str] = None
    likeStatus: Optional[str] = None
    feedbackTokens: Optional[Dict[str, Any]] = None
    listenAgainFeedbackTokens: Optional[Dict[str, Any]] = None


class PlaylistTracks(BaseModel):
    tracks: List[TrackResult]
    playlistId: Optional[str] = None
    lyrics: Optional[str] = None
    related: Optional[str] = None


# Lyrics
class LyricLine(BaseModel):
    text: str
    start_time: int
    end_time: int
    id: int


class SongLyrics(BaseModel):
    lyrics: List[LyricLine]
    source: str
    hasTimestamps: bool = True