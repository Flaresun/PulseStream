from fastapi import APIRouter, BackgroundTasks, Body, HTTPException, Request, status
from fastapi.responses import Response
from app.streamingMusic.models import ClientTrackMetadata, StreamResponseModel, TrackStatusResponse, DeleteTrackResponse
from app.streamingMusic.service import StreamingMusicAPI
from app.core.database import execute_query

router = APIRouter()

# Initialize service with shared global DB execution handlers
streaming_api = StreamingMusicAPI(
    db_execute_fn=execute_query,
)


@router.post("/resolve/{youtube_id}", response_model=StreamResponseModel)
async def resolve_stream(
    youtube_id: str,
    background_tasks: BackgroundTasks,
    request: Request,
    client_metadata: ClientTrackMetadata = Body(...),
):
    """
    Resolves audio stream for AVQueuePlayer using strictly typed client metadata.
    READY tracks return the server-side HLS proxy URL so segment requests stay authorised.
    NOT_CACHED tracks return the YouTube CDN URL (AAC/m4a) and launch the background worker.
    """
    try:
        meta_dict = client_metadata.model_dump()
        return await streaming_api.resolve_track_stream(youtube_id, meta_dict, background_tasks, request)
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to resolve stream for video {youtube_id}"
        )


@router.get("/hls/{youtube_id}/playlist.m3u8")
async def serve_hls_manifest(youtube_id: str, request: Request):
    """
    Fetches playlist.m3u8 from S3 and rewrites each segment line to a server-side
    proxy URL so AVPlayer never contacts S3 directly.
    """
    try:
        manifest = await streaming_api.serve_hls_manifest(youtube_id, request)
        return Response(content=manifest, media_type="application/x-mpegURL")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to serve HLS manifest for {youtube_id}: {str(e)}"
        )


@router.get("/hls/{youtube_id}/{segment}")
async def serve_hls_segment(youtube_id: str, segment: str):
    """
    Fetches a single .ts segment from S3 using server-side credentials and
    streams it to AVPlayer.  The client never needs direct S3 access.
    """
    try:
        data = await streaming_api.serve_hls_segment(youtube_id, segment)
        return Response(content=data, media_type="video/MP2T")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to serve segment {segment} for {youtube_id}: {str(e)}"
        )


@router.get("/status/{youtube_id}", response_model=TrackStatusResponse)
async def get_stream_status(youtube_id: str):
    """
    Returns current S3 caching status ('NOT_CACHED', 'PROCESSING', 'READY', 'FAILED').
    """
    return await streaming_api.get_track_status(youtube_id)


@router.delete("/{youtube_id}", response_model=DeleteTrackResponse)
async def delete_stream_cache(youtube_id: str):
    """
    Purges HLS files from S3 bucket and updates DB status to NOT_CACHED.
    """
    try:
        return await streaming_api.delete_track_s3(youtube_id)
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to delete S3 assets for video {youtube_id}: {str(e)}"
        )