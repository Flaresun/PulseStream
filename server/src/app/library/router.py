from typing import List

from fastapi import APIRouter, HTTPException, status

from app.core.database import execute_query
from app.library.models import (
    AddTrackRequest,
    AddTrackResponse,
    CreatePlaylistRequest,
    PlaylistDetail,
    PlaylistSummary,
    RenamePlaylistRequest,
)
from app.library.service import LibraryAPI, PlaylistFull, PlaylistNotFound

router = APIRouter()
library_api = LibraryAPI(db_execute_fn=execute_query)


def _not_found(e: PlaylistNotFound) -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.get("/playlists", response_model=List[PlaylistSummary])
async def list_playlists():
    return await library_api.list_playlists()


@router.post(
    "/playlists",
    response_model=PlaylistSummary,
    status_code=status.HTTP_201_CREATED,
)
async def create_playlist(payload: CreatePlaylistRequest):
    return await library_api.create_playlist(payload.name)


@router.get("/playlists/{playlist_id}", response_model=PlaylistDetail)
async def get_playlist(playlist_id: int):
    try:
        return await library_api.get_playlist(playlist_id)
    except PlaylistNotFound as e:
        raise _not_found(e)


@router.patch("/playlists/{playlist_id}", response_model=PlaylistDetail)
async def rename_playlist(playlist_id: int, payload: RenamePlaylistRequest):
    try:
        return await library_api.rename_playlist(playlist_id, payload.name)
    except PlaylistNotFound as e:
        raise _not_found(e)


@router.delete("/playlists/{playlist_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_playlist(playlist_id: int):
    try:
        await library_api.delete_playlist(playlist_id)
    except PlaylistNotFound as e:
        raise _not_found(e)


@router.post("/playlists/{playlist_id}/tracks", response_model=AddTrackResponse)
async def add_track(playlist_id: int, payload: AddTrackRequest):
    """
    Adds a song. Returns `added: false` (not an error) when it's already in the
    playlist — duplicates are rejected, and asking twice is harmless.
    """
    try:
        return await library_api.add_track(playlist_id, payload.model_dump())
    except PlaylistNotFound as e:
        raise _not_found(e)
    except PlaylistFull as e:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(e))


@router.delete("/playlists/{playlist_id}/tracks/{video_id}", response_model=AddTrackResponse)
async def remove_track(playlist_id: int, video_id: str):
    try:
        count = await library_api.remove_track(playlist_id, video_id)
    except PlaylistNotFound as e:
        raise _not_found(e)
    # Removing something that isn't there leaves the playlist as it was, which
    # is the state the client wanted either way.
    return AddTrackResponse(added=False, trackCount=count)
