from typing import Any, Awaitable, Callable, List

# This app has no auth/multi-tenancy yet — every play is attributed to this
# single seeded user row (see core/schema.sql and core/database.init_db).
STUB_USER_ID = "00000000-0000-0000-0000-000000000001"

MAX_HISTORY_ENTRIES = 200


class HistoryAPI:
    def __init__(self, db_execute_fn: Callable[[str, tuple], Awaitable[Any]]):
        self.db_execute = db_execute_fn

    async def record_play(
        self,
        youtube_id: str,
        played_duration_seconds: int,
        completion_rate: float,
        was_skipped: bool,
    ) -> None:
        """
        Logs a play event once the client has decided it was a genuine listen
        (crossed the engagement threshold), not on every tap.
        """
        sql_lookup = "SELECT id FROM tracks WHERE youtube_id = %s;"
        result = await self.db_execute(sql_lookup, (youtube_id,))
        if not result:
            raise ValueError(
                f"Track {youtube_id} not found — it must be resolved via /stream/resolve "
                "before a play can be recorded."
            )
        track_id = result[0]["id"]

        sql_insert = """
            INSERT INTO user_playback_history
                (user_id, track_id, played_duration_seconds, completion_rate, was_skipped)
            VALUES (%s, %s, %s, %s, %s);
        """
        await self.db_execute(
            sql_insert,
            (STUB_USER_ID, track_id, played_duration_seconds, completion_rate, was_skipped),
        )

    async def get_history(self, limit: int = MAX_HISTORY_ENTRIES) -> List[dict]:
        """
        Most recent plays first, capped at `limit`. This only limits what's
        returned for display — the underlying user_playback_history table is
        never trimmed, since Speed Dial/Forgotten Favorites/Quick Picks need
        the full history to rank songs correctly.
        """
        sql = """
            SELECT
                h.id AS "historyId",
                t.youtube_id AS "videoId",
                t.title AS "title",
                t.duration_seconds AS "durationSeconds",
                t.thumbnail_url AS "thumbnailUrl",
                EXTRACT(EPOCH FROM h.played_at) AS "playedAt",
                COALESCE(
                    json_agg(
                        json_build_object('name', a.name, 'id', a.browse_id)
                        ORDER BY ta.artist_order
                    ) FILTER (WHERE a.id IS NOT NULL),
                    '[]'
                ) AS artists
            FROM user_playback_history h
            JOIN tracks t ON t.id = h.track_id
            LEFT JOIN track_artists ta ON ta.track_id = t.id
            LEFT JOIN artists a ON a.id = ta.artist_id
            WHERE h.user_id = %s
            GROUP BY h.id, t.id
            ORDER BY h.played_at DESC
            LIMIT %s;
        """
        return await self.db_execute(sql, (STUB_USER_ID, limit))
