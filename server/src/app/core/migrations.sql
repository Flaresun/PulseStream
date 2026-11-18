-- Incremental schema changes, applied on EVERY startup.
--
-- schema.sql only runs on a database that has no `users` table, so it can't
-- carry changes to a deployment that is already live. Anything added here must
-- therefore be idempotent (IF NOT EXISTS / DROP-then-CREATE) and safe to run
-- against both a brand-new database and one several versions old. New changes
-- go at the bottom; nothing here is ever edited in place once deployed.

-- ------------------------------------------------------------------
-- Explicit-content flag
-- ------------------------------------------------------------------
-- Present in schema.sql from the start but never populated. Clients now send
-- it with the track metadata on /stream/resolve and on playlist adds.
ALTER TABLE tracks
    ADD COLUMN IF NOT EXISTS is_explicit BOOLEAN DEFAULT FALSE NOT NULL;

-- ------------------------------------------------------------------
-- Library: user-created playlists
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS playlists (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- A playlist is an ordered index of pointers into the track catalogue; the
-- track rows themselves are shared with history, Home and the S3 cache, so
-- adding a song to a playlist never copies its metadata.
CREATE TABLE IF NOT EXISTS playlist_tracks (
    playlist_id BIGINT REFERENCES playlists(id) ON DELETE CASCADE NOT NULL,
    track_id BIGINT REFERENCES tracks(id) ON DELETE CASCADE NOT NULL,
    position INTEGER NOT NULL,
    added_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    -- Duplicates are rejected by the primary key rather than by a check in
    -- application code, so the guarantee holds no matter who writes.
    PRIMARY KEY (playlist_id, track_id)
);

CREATE INDEX IF NOT EXISTS idx_playlists_user
    ON playlists (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_playlist_tracks_order
    ON playlist_tracks (playlist_id, position);

-- CREATE OR REPLACE TRIGGER needs PG14+; drop-then-create works everywhere and
-- is just as idempotent.
DROP TRIGGER IF EXISTS update_playlists_updated_at ON playlists;
CREATE TRIGGER update_playlists_updated_at
BEFORE UPDATE ON playlists
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();
