"""Shared writes to the track catalogue (`tracks`, `artists`, `track_artists`).

Both /stream/resolve and the library need to register a track the client has
told us about. Streaming additionally locks S3 state, so it keeps its own
upsert; everything that is purely catalogue metadata lives here so the two
paths can't drift apart on, say, how a missing duration is handled.
"""

import logging
from typing import Any, Awaitable, Callable, List, Optional, Sequence

logger = logging.getLogger("uvicorn.error")

DbExecute = Callable[[str, Sequence[Any]], Awaitable[Any]]


async def upsert_artists_and_link(
    db_execute: DbExecute, track_id: int, artists: List[dict]
) -> None:
    """
    Upserts each artist into `artists` and creates the many-to-many links in
    `track_artists`. Best-effort: a bad artist entry is skipped rather than
    failing the whole request, since artist metadata is cosmetic next to
    actually playing the song.

    `artists` entries accept either `browse_id` (the stream payload's spelling)
    or `id` (what search and watch-playlist responses carry).
    """
    for index, artist in enumerate(artists):
        browse_id = artist.get("browse_id") or artist.get("id")
        name = artist.get("name")

        if not browse_id or not name:
            logger.warning(
                f"Artist payload missing required fields for track ID {track_id}. "
                f"Skipping artist: {artist}"
            )
            continue

        try:
            artist_sql = """
                INSERT INTO artists (browse_id, name)
                VALUES (%s, %s)
                ON CONFLICT (browse_id)
                DO UPDATE SET name = EXCLUDED.name
                RETURNING id;
            """
            artist_res = await db_execute(artist_sql, (browse_id, name))

            if not artist_res or not isinstance(artist_res, list) or len(artist_res) == 0:
                logger.error(
                    f"Database returned empty result when upserting artist "
                    f"'{name}' ({browse_id}). Skipping link."
                )
                continue

            artist_id = artist_res[0].get("id")
            if not artist_id:
                logger.error(
                    f"Missing internal 'id' for artist '{name}' ({browse_id}). Skipping link."
                )
                continue

            link_sql = """
                INSERT INTO track_artists (track_id, artist_id, artist_order)
                VALUES (%s, %s, %s)
                ON CONFLICT (track_id, artist_id) DO NOTHING;
            """
            await db_execute(link_sql, (track_id, artist_id, index))

        except Exception as e:
            logger.error(f"Failed to link artist '{name}' to track {track_id}: {e}")
            continue


async def upsert_track_metadata(
    db_execute: DbExecute,
    youtube_id: str,
    title: str,
    duration_seconds: int = 0,
    thumbnail_url: Optional[str] = None,
    is_explicit: bool = False,
    artists: Optional[List[dict]] = None,
) -> int:
    """
    Registers a track in the catalogue and returns its internal id, without
    touching its S3 cache state — adding a song to a playlist must not look
    like a request to (re)download it.

    Fields the client couldn't supply are never allowed to erase what we
    already know: a 0 duration or empty thumbnail leaves the stored value
    alone, and the explicit flag is sticky, because only some upstream
    endpoints report it and losing it would make the badge flicker.
    """
    sql = """
        INSERT INTO tracks (youtube_id, title, duration_seconds, thumbnail_url, is_explicit)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (youtube_id) DO UPDATE SET
            title = EXCLUDED.title,
            duration_seconds = COALESCE(
                NULLIF(EXCLUDED.duration_seconds, 0),
                tracks.duration_seconds
            ),
            thumbnail_url = COALESCE(NULLIF(EXCLUDED.thumbnail_url, ''), tracks.thumbnail_url),
            is_explicit = tracks.is_explicit OR EXCLUDED.is_explicit
        RETURNING id;
    """
    result = await db_execute(
        sql,
        (youtube_id, title, max(0, duration_seconds), thumbnail_url or "", bool(is_explicit)),
    )

    if not result or not isinstance(result, list) or len(result) == 0:
        raise RuntimeError(f"Database returned no row when registering track {youtube_id}")

    track_id = result[0].get("id")
    if not track_id:
        raise RuntimeError(f"Database row missing 'id' when registering track {youtube_id}")

    if artists:
        await upsert_artists_and_link(db_execute, track_id, artists)

    return track_id
