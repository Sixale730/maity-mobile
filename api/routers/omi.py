"""OMI wearable conversations router - Supabase storage with embeddings"""
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field

from fastapi import APIRouter, HTTPException, Query, Depends, Header

from ..services.supabase_client import (
    insert_conversation,
    insert_segments,
    search_conversations_by_embedding,
    search_segments_by_embedding,
    get_conversations,
    get_conversation_with_segments,
    update_conversation_feedback,
)
from ..services.embeddings import generate_embedding, generate_embeddings_batch
from ..services.supabase_auth import get_auth_user_id, optional_auth_user_id
from ..services.communication_analyzer import analyze_communication
from ..models.conversation import TranscriptSegment


router = APIRouter(prefix="/v1/omi", tags=["omi"])


# ============ Request/Response Models ============


class SegmentInput(BaseModel):
    """Input segment from Flutter app"""
    text: str
    speaker: Optional[str] = None
    speaker_id: Optional[int] = 0
    is_user: bool = False
    person_id: Optional[str] = None
    start: float = 0.0
    end: float = 0.0


class StructuredInput(BaseModel):
    """Structured data from Flutter app (already processed by OpenAI)"""
    title: str
    overview: str
    emoji: str = ""
    category: str = "other"
    action_items: List[dict] = Field(default_factory=list)
    events: List[dict] = Field(default_factory=list)


class StoreConversationRequest(BaseModel):
    """Request to store a processed conversation"""
    user_id: str  # UUID de maity.users
    started_at: datetime
    finished_at: datetime
    structured: StructuredInput
    transcript_segments: List[SegmentInput]
    source: str = "omi"
    language: Optional[str] = None
    generate_embeddings: bool = True


class StoreConversationResponse(BaseModel):
    """Response from storing a conversation"""
    id: str
    created_at: str
    embedding_generated: bool


class SearchRequest(BaseModel):
    """Request for semantic search"""
    query: str
    user_id: str  # UUID de maity.users
    limit: int = 10
    search_type: str = "conversations"  # or "segments"
    similarity_threshold: float = 0.7
    include_discarded: bool = False


class SearchResponse(BaseModel):
    """Response from semantic search"""
    results: List[dict]
    query: str
    count: int


# ============ Endpoints ============


@router.post("/conversations/store", response_model=StoreConversationResponse)
async def store_conversation(
    request: StoreConversationRequest,
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Store a processed conversation with embeddings in Supabase.

    The Flutter app sends already-processed data (title, overview, etc.).
    This endpoint:
    1. Generates embeddings for semantic search
    2. Stores conversation in maity.omi_conversations
    3. Stores segments in maity.omi_transcript_segments

    Note: JWT validation is optional during migration period.
    The user_id in the request body is used for storage.
    """
    if not request.transcript_segments:
        raise HTTPException(status_code=400, detail="No transcript segments provided")

    # Build full transcript text
    transcript_text = "\n".join([s.text for s in request.transcript_segments])

    # Calculate metrics
    words_count = sum(len(s.text.split()) for s in request.transcript_segments)
    duration_seconds = 0
    if request.transcript_segments:
        first = request.transcript_segments[0]
        last = request.transcript_segments[-1]
        if last.end > 0:
            duration_seconds = int(last.end - first.start)

    # Generate embeddings if requested
    conversation_embedding = None
    segment_embeddings = None

    if request.generate_embeddings:
        try:
            # Generate conversation embedding
            conversation_embedding = await generate_embedding(transcript_text)

            # Generate segment embeddings in batch (only for segments with enough text)
            segment_texts = [s.text for s in request.transcript_segments]
            segment_embeddings = await generate_embeddings_batch(segment_texts)

        except Exception as e:
            print(f"[OMI Router] Embedding generation failed: {e}")
            # Continue without embeddings

    # Insert conversation
    try:
        result = await insert_conversation(
            user_id=request.user_id,
            title=request.structured.title,
            overview=request.structured.overview,
            emoji=request.structured.emoji,
            category=request.structured.category,
            action_items=request.structured.action_items,
            events=request.structured.events,
            transcript_text=transcript_text,
            embedding=conversation_embedding,
            words_count=words_count,
            duration_seconds=duration_seconds,
            started_at=request.started_at,
            finished_at=request.finished_at,
            source=request.source,
            language=request.language,
        )

        conversation_id = result["id"]

        # Insert segments
        segments_data = [
            {
                "text": s.text,
                "speaker": s.speaker,
                "speaker_id": s.speaker_id,
                "is_user": s.is_user,
                "person_id": s.person_id,
                "start": s.start,
                "end": s.end,
            }
            for s in request.transcript_segments
        ]

        await insert_segments(
            conversation_id=conversation_id,
            user_id=request.user_id,
            segments=segments_data,
            embeddings=segment_embeddings,
        )

        # Analyze communication in background (non-blocking)
        # Convert SegmentInput to TranscriptSegment for analyzer
        try:
            transcript_segments = [
                TranscriptSegment(
                    text=s.text,
                    speaker=s.speaker,
                    speaker_id=s.speaker_id,
                    is_user=s.is_user,
                    start=s.start,
                    end=s.end,
                )
                for s in request.transcript_segments
            ]

            communication_feedback = await analyze_communication(transcript_segments)

            if communication_feedback:
                feedback_dict = {
                    "strengths": communication_feedback.strengths,
                    "areas_to_improve": communication_feedback.areas_to_improve,
                    "observations": {
                        "clarity": communication_feedback.observations.clarity,
                        "structure": communication_feedback.observations.structure,
                        "calls_to_action": communication_feedback.observations.calls_to_action,
                        "objections": communication_feedback.observations.objections,
                    },
                    "summary": communication_feedback.summary,
                }

                await update_conversation_feedback(
                    conversation_id=conversation_id,
                    user_id=request.user_id,
                    communication_feedback=feedback_dict,
                )
                print(f"[OMI Router] Communication feedback generated for {conversation_id}")

        except Exception as e:
            # Don't fail the request if communication analysis fails
            print(f"[OMI Router] Communication analysis failed (non-blocking): {e}")

        return StoreConversationResponse(
            id=conversation_id,
            created_at=result["created_at"],
            embedding_generated=conversation_embedding is not None,
        )

    except Exception as e:
        print(f"[OMI Router] Failed to store conversation: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to store conversation: {str(e)}")


@router.post("/conversations/search", response_model=SearchResponse)
async def search_conversations(
    request: SearchRequest,
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Semantic search for conversations or segments using vector similarity.

    Uses pgvector cosine similarity search with embeddings.
    """
    if not request.query or len(request.query.strip()) < 2:
        return SearchResponse(results=[], query=request.query, count=0)

    # Generate query embedding
    query_embedding = await generate_embedding(request.query)

    if not query_embedding:
        # Fallback: return empty results if embedding fails
        return SearchResponse(results=[], query=request.query, count=0)

    try:
        if request.search_type == "segments":
            results = await search_segments_by_embedding(
                user_id=request.user_id,
                query_embedding=query_embedding,
                limit=request.limit,
                similarity_threshold=request.similarity_threshold,
            )
        else:
            results = await search_conversations_by_embedding(
                user_id=request.user_id,
                query_embedding=query_embedding,
                limit=request.limit,
                similarity_threshold=request.similarity_threshold,
                include_discarded=request.include_discarded,
            )

        return SearchResponse(
            results=results,
            query=request.query,
            count=len(results),
        )

    except Exception as e:
        print(f"[OMI Router] Search failed: {e}")
        return SearchResponse(results=[], query=request.query, count=0)


@router.get("/conversations")
async def list_conversations(
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    limit: int = Query(50, ge=1, le=100, description="Max conversations to return"),
    offset: int = Query(0, ge=0, description="Offset for pagination"),
    include_discarded: bool = Query(False, description="Include discarded conversations"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    List user's conversations from Supabase.

    Returns conversations sorted by creation date (newest first).
    """
    try:
        conversations = await get_conversations(
            user_id=user_id,
            limit=limit,
            offset=offset,
            include_discarded=include_discarded,
        )

        return {
            "conversations": conversations,
            "count": len(conversations),
            "limit": limit,
            "offset": offset,
        }

    except Exception as e:
        print(f"[OMI Router] List conversations failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to fetch conversations: {str(e)}")


@router.get("/conversations/{conversation_id}")
async def get_single_conversation(
    conversation_id: str,
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Get a single conversation with all its transcript segments.
    """
    try:
        result = await get_conversation_with_segments(
            user_id=user_id,
            conversation_id=conversation_id,
        )

        if not result:
            raise HTTPException(status_code=404, detail="Conversation not found")

        return result

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Get conversation failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to fetch conversation: {str(e)}")
