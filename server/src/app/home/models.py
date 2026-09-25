from typing import List, Optional
from pydantic import BaseModel

from app.staticMusic.models import Artist, Thumbnail


class HomeSong(BaseModel):
    videoId: str
    title: str
    artists: List[Artist] = []
    thumbnails: List[Thumbnail] = []
    durationSeconds: Optional[int] = None


class HomeResponse(BaseModel):
    speedDial: List[HomeSong]
    forgottenFavorites: List[HomeSong]
    quickPicks: List[HomeSong]
    explore: List[HomeSong]
