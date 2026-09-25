import asyncio
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Dict, List, Optional, Set

from app.history.service import STUB_USER_ID
from app.staticMusic.models import Song, TrackResult
from app.staticMusic.service import StaticMusicAPI

# "Frecency" half-life: a play today contributes ~1.0 to a track's score, a
# play this many days ago contributes ~0.5, decaying continuously. Frequency
# and recency both fall out of the same summed score.
FRECENCY_HALF_LIFE_SECONDS = 14 * 86400.0

SPEED_DIAL_LIMIT = 27
FORGOTTEN_FAVORITES_LIMIT = 10
FORGOTTEN_FAVORITES_STALE_SECONDS = 7 * 86400.0
QUICK_PICKS_MAX_PLAYS = 2
QUICK_PICKS_LIMIT = 40
EXPLORE_LIMIT = 20

# Used only to seed Explore when a user has no listening history yet (cold
# start) or when the seeded watch-playlist doesn't yield enough new songs.
EXPLORE_FALLBACK_QUERY = "top hits"


def _parse_duration_seconds(text: Optional[str]) -> Optional[int]:
    if not text:
        return None
    parts = text.split(":")
    try:
        parts = [int(p) for p in parts]
    except ValueError:
        return None
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return None


def _song_to_home_song(song: Song) -> Dict[str, Any]:
    return {
        "videoId": song.videoId,
        "title": song.title,
        "artists": [a.model_dump() for a in song.artists],
        "thumbnails": [t.model_dump() for t in song.thumbnails],
        "durationSeconds": song.duration_seconds,
    }


def _track_result_to_home_song(track: TrackResult) -> Dict[str, Any]:
    return {
        "videoId": track.videoId,
        "title": track.title,
        "artists": [a.model_dump() for a in track.artists],
        "thumbnails": [t.model_dump() for t in track.thumbnail],
        "durationSeconds": _parse_duration_seconds(track.length),
    }


class HomeAPI:
    def __init__(
        self,
        db_execute_fn: Callable[[str, tuple], Awaitable[Any]],
        static_music_api: StaticMusicAPI,
    ):
        self.db_execute = db_execute_fn
        self.static_music_api = static_music_api

    async def get_home(self) -> Dict[str, List[Dict[str, Any]]]:
        stats = await self._get_track_stats()

        # Partition on staleness FIRST: a track not played in 7+ days must
        # never be Speed-Dial-eligible, no matter how high its historical
        # play count pushes its frecency — otherwise a heavily-played-but-old
        # track can outrank a lightly-played-but-recent one on pure frecency
        # and never reach Forgotten Favorites. This also makes Speed Dial and
        # Forgotten Favorites disjoint by construction, not by hoping decay
        # pushed the score low enough.
        stale_cutoff = datetime.now(timezone.utc).timestamp() - FORGOTTEN_FAVORITES_STALE_SECONDS
        active = [t for t in stats if t["lastPlayedAt"] >= stale_cutoff]
        stale = [t for t in stats if t["lastPlayedAt"] < stale_cutoff]

        speed_dial = sorted(active, key=lambda t: t["frecency"], reverse=True)[:SPEED_DIAL_LIMIT]
        speed_dial_ids = {t["trackId"] for t in speed_dial}

        forgotten_favorites = sorted(
            stale, key=lambda t: t["playCount"], reverse=True
        )[:FORGOTTEN_FAVORITES_LIMIT]

        remaining_active = [t for t in active if t["trackId"] not in speed_dial_ids]
        quick_picks = sorted(
            (t for t in remaining_active if t["playCount"] <= QUICK_PICKS_MAX_PLAYS),
            key=lambda t: t["lastPlayedAt"],
            reverse=True,
        )[:QUICK_PICKS_LIMIT]

        played_ids = {t["videoId"] for t in stats}
        seed_video_id = speed_dial[0]["videoId"] if speed_dial else None
        explore = await self._build_explore(seed_video_id, played_ids)

        return {
            "speedDial": [self._strip_stats(t) for t in speed_dial],
            "forgottenFavorites": [self._strip_stats(t) for t in forgotten_favorites],
            "quickPicks": [self._strip_stats(t) for t in quick_picks],
            "explore": explore,
        }

    @staticmethod
    def _strip_stats(track: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "videoId": track["videoId"],
            "title": track["title"],
            "artists": track["artists"],
            "thumbnails": [{"url": track["thumbnailUrl"], "width": 0, "height": 0}] if track["thumbnailUrl"] else [],
            "durationSeconds": track["durationSeconds"],
        }

    async def _get_track_stats(self) -> List[Dict[str, Any]]:
        sql = """
            WITH track_stats AS (
                SELECT
                    h.track_id,
                    COUNT(*) AS play_count,
                    MAX(h.played_at) AS last_played_at,
                    SUM(
                        EXP(-EXTRACT(EPOCH FROM (NOW() - h.played_at)) / %s * LN(2))
                    ) AS frecency
                FROM user_playback_history h
                WHERE h.user_id = %s
                GROUP BY h.track_id
            ),
            track_artist_agg AS (
                SELECT
                    ta.track_id,
                    json_agg(
                        json_build_object('name', a.name, 'id', a.browse_id)
                        ORDER BY ta.artist_order
                    ) AS artists
                FROM track_artists ta
                JOIN artists a ON a.id = ta.artist_id
                GROUP BY ta.track_id
            )
            SELECT
                t.id AS "trackId",
                t.youtube_id AS "videoId",
                t.title AS "title",
                t.duration_seconds AS "durationSeconds",
                t.thumbnail_url AS "thumbnailUrl",
                s.play_count AS "playCount",
                EXTRACT(EPOCH FROM s.last_played_at) AS "lastPlayedAt",
                s.frecency AS "frecency",
                COALESCE(taa.artists, '[]') AS artists
            FROM track_stats s
            JOIN tracks t ON t.id = s.track_id
            LEFT JOIN track_artist_agg taa ON taa.track_id = t.id;
        """
        return await self.db_execute(sql, (FRECENCY_HALF_LIFE_SECONDS, STUB_USER_ID))

    async def _build_explore(
        self, seed_video_id: Optional[str], played_ids: Set[str]
    ) -> List[Dict[str, Any]]:
        candidates: List[Dict[str, Any]] = []
        seen: Set[str] = set()

        def add(entries: List[Dict[str, Any]]) -> None:
            for entry in entries:
                video_id = entry.get("videoId")
                if not video_id or video_id in played_ids or video_id in seen:
                    continue
                seen.add(video_id)
                candidates.append(entry)

        if seed_video_id:
            try:
                playlist = await asyncio.to_thread(
                    self.static_music_api.getNextSongs, seed_video_id
                )
                if playlist:
                    add([_track_result_to_home_song(t) for t in playlist.tracks])
            except Exception:
                pass  # fall through to the broader fallback below

        if len(candidates) < EXPLORE_LIMIT:
            try:
                songs = await asyncio.to_thread(
                    self.static_music_api.getSong, EXPLORE_FALLBACK_QUERY
                )
                if songs:
                    add([_song_to_home_song(s) for s in songs])
            except Exception:
                pass

        return candidates[:EXPLORE_LIMIT]
