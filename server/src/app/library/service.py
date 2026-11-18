from typing import Any, Awaitable, Callable, Dict, List, Optional, Sequence

from app.core.catalog import upsert_track_metadata
from app.history.service import STUB_USER_ID

# Covers shown on a playlist row in the library list.
PLAYLIST_COVER_COUNT = 4

# Guard rail on an unbounded table; well past any realistic hand-built playlist.
MAX_TRACKS_PER_PLAYLIST = 1000


class PlaylistNotFound(Exception):
    """Raised when a playlist id doesn't exist for the current user."""


class PlaylistFull(Exception):
    """Raised when a playlist has hit MAX_TRACKS_PER_PLAYLIST."""


class LibraryAPI:
    def __init__(self, db_execute_fn: Callable[[str, Sequence[Any]], Awaitable[Any]]):
        self.db_execute = db_execute_fn

    # ------------------------------------------------------------------
    # Playlists
    # ------------------------------------------------------------------

    async def list_playlists(self) -> List[Dict[str, Any]]:
        """Newest first, each with its track count and a few cover images."""
        sql = """
            SELECT
                p.id AS "id",
                p.name AS "name",
                EXTRACT(EPOCH FROM p.created_at) AS "createdAt",
                EXTRACT(EPOCH FROM p.updated_at) AS "updatedAt",
                COUNT(pt.track_id) AS "trackCount",
                COALESCE(
                    (
                        SELECT array_agg(thumb)
                        FROM (
                            SELECT t2.thumbnail_url AS thumb
                            FROM playlist_tracks pt2
                            JOIN tracks t2 ON t2.id = pt2.track_id
                            WHERE pt2.playlist_id = p.id AND t2.thumbnail_url IS NOT NULL
                            ORDER BY pt2.position
                            LIMIT %s
                        ) covers
                    ),
                    ARRAY[]::text[]
                ) AS "thumbnailUrls"
            FROM playlists p
            LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
            WHERE p.user_id = %s
            GROUP BY p.id
            ORDER BY p.created_at DESC;
        """
        rows = await self.db_execute(sql, (PLAYLIST_COVER_COUNT, STUB_USER_ID))
        return [self._normalise_summary(row) for row in (rows or [])]

    async def create_playlist(self, name: str) -> Dict[str, Any]:
        sql = """
            INSERT INTO playlists (user_id, name)
            VALUES (%s, %s)
            RETURNING
                id AS "id",
                name AS "name",
                EXTRACT(EPOCH FROM created_at) AS "createdAt",
                EXTRACT(EPOCH FROM updated_at) AS "updatedAt";
        """
        rows = await self.db_execute(sql, (STUB_USER_ID, name.strip()))
        if not rows:
            raise RuntimeError("Database returned no row when creating a playlist")

        created = self._normalise_summary(rows[0])
        created["trackCount"] = 0
        created["thumbnailUrls"] = []
        return created

    async def rename_playlist(self, playlist_id: int, name: str) -> Dict[str, Any]:
        sql = """
            UPDATE playlists
            SET name = %s
            WHERE id = %s AND user_id = %s
            RETURNING id;
        """
        rows = await self.db_execute(sql, (name.strip(), playlist_id, STUB_USER_ID))
        if not rows:
            raise PlaylistNotFound(f"Playlist {playlist_id} not found")
        return await self.get_playlist(playlist_id)

    async def delete_playlist(self, playlist_id: int) -> None:
        # playlist_tracks rows go with it via ON DELETE CASCADE; the tracks
        # themselves are shared catalogue rows and are left alone.
        sql = "DELETE FROM playlists WHERE id = %s AND user_id = %s RETURNING id;"
        rows = await self.db_execute(sql, (playlist_id, STUB_USER_ID))
        if not rows:
            raise PlaylistNotFound(f"Playlist {playlist_id} not found")

    async def get_playlist(self, playlist_id: int) -> Dict[str, Any]:
        header_sql = """
            SELECT
                id AS "id",
                name AS "name",
                EXTRACT(EPOCH FROM created_at) AS "createdAt",
                EXTRACT(EPOCH FROM updated_at) AS "updatedAt"
            FROM playlists
            WHERE id = %s AND user_id = %s;
        """
        header_rows = await self.db_execute(header_sql, (playlist_id, STUB_USER_ID))
        if not header_rows:
            raise PlaylistNotFound(f"Playlist {playlist_id} not found")

        tracks = await self._get_tracks(playlist_id)
        detail = self._normalise_summary(header_rows[0])
        detail["tracks"] = tracks
        detail["trackCount"] = len(tracks)
        detail["thumbnailUrls"] = [
            t["thumbnailUrl"] for t in tracks if t.get("thumbnailUrl")
        ][:PLAYLIST_COVER_COUNT]
        return detail

    # ------------------------------------------------------------------
    # Playlist contents
    # ------------------------------------------------------------------

    async def add_track(self, playlist_id: int, payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        Adds a track, registering it in the catalogue first if this is the
        first time we've seen it — a song can be added straight from search
        without ever having been played.

        Adding a song that's already in the playlist is a no-op rather than an
        error; the primary key on (playlist_id, track_id) is what actually
        rejects the duplicate.
        """
        await self._assert_exists(playlist_id)

        count = await self._track_count(playlist_id)
        if count >= MAX_TRACKS_PER_PLAYLIST:
            raise PlaylistFull(
                f"Playlist {playlist_id} already holds {MAX_TRACKS_PER_PLAYLIST} tracks"
            )

        track_id = await upsert_track_metadata(
            self.db_execute,
            youtube_id=payload["videoId"],
            title=payload["title"],
            duration_seconds=payload.get("durationSeconds") or 0,
            thumbnail_url=payload.get("thumbnailUrl"),
            is_explicit=bool(payload.get("isExplicit")),
            artists=payload.get("artists") or [],
        )

        # Positions only ever grow, so a removal never forces a renumber.
        insert_sql = """
            INSERT INTO playlist_tracks (playlist_id, track_id, position)
            VALUES (
                %s,
                %s,
                COALESCE(
                    (SELECT MAX(position) + 1 FROM playlist_tracks WHERE playlist_id = %s),
                    0
                )
            )
            ON CONFLICT (playlist_id, track_id) DO NOTHING
            RETURNING track_id;
        """
        rows = await self.db_execute(insert_sql, (playlist_id, track_id, playlist_id))
        added = bool(rows)

        return {"added": added, "trackCount": count + (1 if added else 0)}

    async def remove_track(self, playlist_id: int, video_id: str) -> int:
        await self._assert_exists(playlist_id)
        sql = """
            DELETE FROM playlist_tracks
            WHERE playlist_id = %s
              AND track_id = (SELECT id FROM tracks WHERE youtube_id = %s)
            RETURNING track_id;
        """
        await self.db_execute(sql, (playlist_id, video_id))
        return await self._track_count(playlist_id)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    async def _get_tracks(self, playlist_id: int) -> List[Dict[str, Any]]:
        sql = """
            SELECT
                t.youtube_id AS "videoId",
                t.title AS "title",
                t.duration_seconds AS "durationSeconds",
                t.thumbnail_url AS "thumbnailUrl",
                t.is_explicit AS "isExplicit",
                pt.position AS "position",
                COALESCE(
                    json_agg(
                        json_build_object('name', a.name, 'id', a.browse_id)
                        ORDER BY ta.artist_order
                    ) FILTER (WHERE a.id IS NOT NULL),
                    '[]'
                ) AS artists
            FROM playlist_tracks pt
            JOIN tracks t ON t.id = pt.track_id
            LEFT JOIN track_artists ta ON ta.track_id = t.id
            LEFT JOIN artists a ON a.id = ta.artist_id
            WHERE pt.playlist_id = %s
            GROUP BY t.id, pt.position
            ORDER BY pt.position;
        """
        return list(await self.db_execute(sql, (playlist_id,)) or [])

    async def _assert_exists(self, playlist_id: int) -> None:
        rows = await self.db_execute(
            "SELECT id FROM playlists WHERE id = %s AND user_id = %s;",
            (playlist_id, STUB_USER_ID),
        )
        if not rows:
            raise PlaylistNotFound(f"Playlist {playlist_id} not found")

    async def _track_count(self, playlist_id: int) -> int:
        rows = await self.db_execute(
            'SELECT COUNT(*) AS "count" FROM playlist_tracks WHERE playlist_id = %s;',
            (playlist_id,),
        )
        return int(rows[0]["count"]) if rows else 0

    @staticmethod
    def _normalise_summary(row: Dict[str, Any]) -> Dict[str, Any]:
        summary = dict(row)
        summary["id"] = int(summary["id"])
        summary["trackCount"] = int(summary.get("trackCount") or 0)
        # array_agg hands back None for an empty playlist, and psycopg may give
        # a tuple rather than a list.
        covers: Optional[Any] = summary.get("thumbnailUrls")
        summary["thumbnailUrls"] = [c for c in list(covers or []) if c]
        return summary
