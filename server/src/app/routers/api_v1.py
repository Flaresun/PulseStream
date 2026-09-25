from fastapi import APIRouter
from app.staticMusic.router import router as staticMusicRouter
from app.streamingMusic.router import router as streamingMusicRouter
from app.history.router import router as historyRouter
from app.home.router import router as homeRouter

# Main aggregator router
v1_router = APIRouter()

# Sub routes
v1_router.include_router(staticMusicRouter, prefix="/songs", tags=["Songs"])
v1_router.include_router(streamingMusicRouter, prefix="/stream", tags=["Stream"])
v1_router.include_router(historyRouter, prefix="/history", tags=["History"])
v1_router.include_router(homeRouter, prefix="/home", tags=["Home"])
