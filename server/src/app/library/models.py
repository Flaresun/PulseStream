from typing import List, Optional

from pydantic import BaseModel, Field


class LibraryArtist(BaseModel):
    name: str
    id: Optional[str] = None


class PlaylistTrack(BaseModel):
    videoId: str
    title: str
    artists: List[LibraryArtist] = []
    durationSeconds: int = 0
    thumbnailUrl: Optional[str] = None
    isExplicit: bool = False
    # Ordinal within the playlist. Sparse and monotonic rather than a dense
    # 0..n-1 range, so removing a track doesn't require renumbering the rest.
    position: int = 0


class PlaylistSummary(BaseModel):
    id: int
    name: str
    trackCount: int = 0
    # Up to four covers, oldest first, for the list artwork.
    thumbnailUrls: List[str] = []
    createdAt: float
    updatedAt: float


class PlaylistDetail(PlaylistSummary):
    tracks: List[PlaylistTrack] = []


class CreatePlaylistRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)


class RenamePlaylistRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)


class AddTrackRequest(BaseModel):
    """
    Everything needed to register a track that may not be in the catalogue yet
    — a song can be added to a playlist without ever having been played, so we
    can't assume /stream/resolve has run for it.
    """
    videoId: str
    title: str
    durationSeconds: int = Field(0, ge=0)
    thumbnailUrl: Optional[str] = None
    isExplicit: bool = False
    artists: List[LibraryArtist] = []


class AddTrackResponse(BaseModel):
    # False when the track was already in the playlist. Not an error: adding a
    # song twice is a no-op, since playlists reject duplicates.
    added: bool
    trackCount: int
