from typing import List, Optional
from pydantic import BaseModel, Field


class HistoryArtist(BaseModel):
    name: str
    id: Optional[str] = None


class HistoryEntry(BaseModel):
    historyId: int
    videoId: str
    title: str
    artists: List[HistoryArtist]
    durationSeconds: int
    thumbnailUrl: Optional[str] = None
    playedAt: float  # epoch seconds


class RecordPlayRequest(BaseModel):
    playedDurationSeconds: int = Field(..., ge=0)
    completionRate: float = Field(..., ge=0.0, le=1.0)
    wasSkipped: bool = False
