from fastapi import APIRouter

from app.core.database import execute_query
from app.home.models import HomeResponse
from app.home.service import HomeAPI
from app.staticMusic.service import StaticMusicAPI

router = APIRouter()
home_api = HomeAPI(db_execute_fn=execute_query, static_music_api=StaticMusicAPI())


@router.get("", response_model=HomeResponse)
async def get_home():
    return await home_api.get_home()
