from typing import List

from fastapi import APIRouter, HTTPException, status

from app.core.database import execute_query
from app.history.models import HistoryEntry, RecordPlayRequest
from app.history.service import HistoryAPI

router = APIRouter()
history_api = HistoryAPI(db_execute_fn=execute_query)


@router.post("/play/{youtube_id}", status_code=status.HTTP_204_NO_CONTENT)
async def record_play(youtube_id: str, payload: RecordPlayRequest):
    try:
        await history_api.record_play(
            youtube_id=youtube_id,
            played_duration_seconds=payload.playedDurationSeconds,
            completion_rate=payload.completionRate,
            was_skipped=payload.wasSkipped,
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.get("", response_model=List[HistoryEntry])
async def get_history():
    return await history_api.get_history()
