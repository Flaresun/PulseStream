from ytmusicapi import YTMusic
from app.staticMusic.models import Song, ArtistResult,AlbumDetails,PlaylistTracks, SongLyrics
from typing import List, Any, Optional, Dict

class StaticMusicAPI:
    def __init__(self):
        self.ytmusic = YTMusic(language="en")

    def _search(self, item: str, filter: str) -> Optional[List[Dict[str, Any]]]:
        if not item:
            return None
        return self.ytmusic.search(item, filter=filter)

    def getSong(self, title: str) -> Optional[List[Song]]:
        res = self._search(title, "songs")
        if not res:
            return None
        return [Song.model_validate(song) for song in res]

    def getSongMetadata(self, videoId: str) -> Optional[List[Song]]:
            return self.ytmusic.get_song(videoId).get("videoDetails")

    def getArtist(self, artist: str) -> Optional[List[ArtistResult]]:
        res = self._search(artist, "artists")
        if not res:
            return None
        return [ArtistResult.model_validate(a) for a in res]

    def getAlbum(self, albumId: str) -> Optional[AlbumDetails]:
        if not albumId:
            return None
        album = self.ytmusic.get_album(albumId)
        return AlbumDetails.model_validate(album) if album else None

    def getNextSongs(self, currentVideoId: str) -> Optional[PlaylistTracks]:
        if not currentVideoId:
            return None
        watch_playlist = self.ytmusic.get_watch_playlist(currentVideoId)
        return PlaylistTracks.model_validate(watch_playlist) if watch_playlist else None

    def getLyrics(self, songId: str) -> SongLyrics:
        """Fetch song lyrics using a lyrics browse ID.

        :param songId: Must be the `lyrics` browse ID string obtained from a
                          `PlaylistResult` or `TrackResult` object (e.g., 'MPLYt_...'),
                          NOT a standard YouTube videoId or track ID.
        :returns: A `SongLyrics` object; `lyrics` is empty when the song has
                  none. Always a well-formed object rather than `None`, so the
                  client can tell "no lyrics for this song" apart from a
                  request that failed.
        """
        empty = SongLyrics(lyrics=[], source="", hasTimestamps=False)
        if not songId:
            return empty
        raw_lyrics = None
        try:
            raw_lyrics = self.ytmusic.get_lyrics(songId, True)
        except Exception:
            # Asking for timestamps on a song that only has untimed lyrics makes
            # ytmusicapi's cue parser raise (KeyError 'cueRange'). That is a very
            # common case, and treating it as "no lyrics" is why the lyrics panel
            # came up empty for so many songs — ask again without timestamps.
            try:
                raw_lyrics = self.ytmusic.get_lyrics(songId, False)
            except Exception:
                return empty
        if not raw_lyrics:
            return empty

        raw_lines = raw_lyrics.get("lyrics")
        has_timestamps = bool(raw_lyrics.get("hasTimestamps", True))

        if isinstance(raw_lines, str):
            # Songs without timed lyrics come back as one newline-separated
            # blob instead of a list of cues. These used to be dropped on the
            # floor, so the client got a valid-looking response with zero lines
            # and rendered an empty lyrics panel.
            lines = [
                {"text": text, "start_time": 0, "end_time": 0, "id": index}
                for index, text in enumerate(raw_lines.splitlines())
                if text.strip()
            ]
            has_timestamps = False
        elif isinstance(raw_lines, list):
            lines = [
                line if isinstance(line, dict) else {
                    "text": line.text,
                    "start_time": line.start_time,
                    "end_time": line.end_time,
                    "id": line.id,
                }
                for line in raw_lines
            ]
        else:
            lines = []

        return SongLyrics.model_validate({
            "lyrics": lines,
            "source": raw_lyrics.get("source") or "",
            "hasTimestamps": has_timestamps,
        })

    def getSearchSuggestions(self, search: str) -> Optional[List[str]]:
        if not search:
            return None
        return self.ytmusic.get_search_suggestions(search)
        

