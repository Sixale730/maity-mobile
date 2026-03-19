"""OMI wearable conversations router - Supabase storage with embeddings"""
from datetime import datetime
from typing import List, Optional
from uuid import uuid4
from pydantic import BaseModel, Field

from fastapi import APIRouter, HTTPException, Query, Depends, Header, Response

from ..services.supabase_client import (
    insert_conversation,
    insert_segments,
    insert_draft_conversation,
    append_segments,
    finalize_conversation,
    search_conversations_by_embedding,
    search_segments_by_embedding,
    get_conversations,
    get_conversation_with_segments,
    update_conversation_feedback,
    update_conversation_starred,
    delete_conversation,
    get_supabase,
)
from ..services.embeddings import generate_embedding, generate_embeddings_batch
from ..services.supabase_auth import (
    get_auth_user_id,
    optional_auth_user_id,
    resolve_maity_user_id,
    verify_conversation_ownership,
)
from ..services.communication_analyzer import analyze_communication
from ..services.memory_extractor import extract_memories_from_transcript
from ..services.chunked_processor import process_long_transcript
from ..models.conversation import TranscriptSegment


router = APIRouter(prefix="/v1/omi", tags=["omi"])


def should_auto_discard(words_count: int, duration_seconds: int, segment_count: int) -> bool:
    """Check if a conversation should be automatically discarded as trivial.

    Rules:
    1. Less than 5 words total
    2. Less than 10 seconds AND less than 10 words
    3. Single segment with less than 3 words
    """
    if words_count < 5:
        return True
    if duration_seconds < 10 and words_count < 10:
        return True
    if segment_count == 1 and words_count < 3:
        return True
    return False


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
    discarded: bool = False  # True if AI marked conversation as banal/irrelevant


class StoreConversationRequest(BaseModel):
    """Request to store a processed conversation"""
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
    similarity_threshold: float = 0.3
    include_discarded: bool = False


class SearchResponse(BaseModel):
    """Response from semantic search"""
    results: List[dict]
    query: str
    count: int


class DraftConversationRequest(BaseModel):
    """Request to create a draft conversation (recording in progress)"""
    started_at: datetime
    source: str = "omi"


class DraftConversationResponse(BaseModel):
    """Response from creating a draft conversation"""
    id: str
    created_at: str


class AppendSegmentsRequest(BaseModel):
    """Request to append segments to a draft conversation"""
    segments: List[SegmentInput]
    segment_offset: int = 0


class AppendSegmentsResponse(BaseModel):
    """Response from appending segments"""
    inserted: int
    total_segments: int


class FinalizeConversationRequest(BaseModel):
    """Request to finalize a draft conversation"""
    finished_at: datetime
    structured: Optional[StructuredInput] = None
    generate_embeddings: bool = True


class FinalizeConversationResponse(BaseModel):
    """Response from finalizing a conversation"""
    id: str
    transcript_rebuilt: bool
    words_count: int
    duration_seconds: int
    segment_count: int
    embedding_generated: bool
    chunked_processing: bool = False


class UpdateStatusRequest(BaseModel):
    status: str = Field(..., description="New status")
    deleted: Optional[bool] = None


class StoreAndProcessRequest(BaseModel):
    """Request to store and process a conversation in one call.

    Replaces the 3-step draft -> segments -> finalize flow.
    """
    segments: List[SegmentInput]
    started_at: datetime
    finished_at: datetime
    language: Optional[str] = None
    source: str = "omi"
    structured: Optional[StructuredInput] = None
    generate_embeddings: bool = True
    idempotency_key: Optional[str] = None


class StoreAndProcessResponse(BaseModel):
    """Response from store-and-process endpoint."""
    id: str
    title: str
    emoji: str
    category: str
    overview: str
    discarded: bool
    words_count: int
    duration_seconds: int
    segment_count: int
    embedding_generated: bool
    chunked_processing: bool = False


# ============ Endpoints ============


@router.post("/conversations/draft", response_model=DraftConversationResponse, deprecated=True)
async def create_draft_conversation(
    request: DraftConversationRequest,
    response: Response,
    auth_id: str = Depends(get_auth_user_id),
):
    """
    Create a draft conversation with status='recording'.

    Called when recording starts to get a conversation UUID for
    incremental segment saving.

    **Deprecated**: Use POST /conversations/store-and-process instead.
    """
    response.headers["Deprecation"] = "true"
    response.headers["Sunset"] = "2026-06-01"
    response.headers["Link"] = '</v1/omi/conversations/store-and-process>; rel="successor-version"'
    try:
        user_id = await resolve_maity_user_id(auth_id)

        result = await insert_draft_conversation(
            user_id=user_id,
            started_at=request.started_at,
            source=request.source,
        )

        print(f"[OMI Router] Draft conversation created: {result['id']}")

        return DraftConversationResponse(
            id=result["id"],
            created_at=result["created_at"],
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Failed to create draft: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to create draft: {str(e)}")


@router.post("/conversations/{conversation_id}/segments", response_model=AppendSegmentsResponse, deprecated=True)
async def append_conversation_segments(
    conversation_id: str,
    request: AppendSegmentsRequest,
    response: Response,
    auth_id: str = Depends(get_auth_user_id),
):
    """
    Append segments to a draft conversation.

    Idempotent: uses ON CONFLICT DO NOTHING on (conversation_id, segment_index).
    Safe to retry on network errors.

    **Deprecated**: Use POST /conversations/store-and-process instead.
    """
    response.headers["Deprecation"] = "true"
    response.headers["Sunset"] = "2026-06-01"
    response.headers["Link"] = '</v1/omi/conversations/store-and-process>; rel="successor-version"'

    if not request.segments:
        return AppendSegmentsResponse(inserted=0, total_segments=request.segment_offset)

    try:
        user_id = await resolve_maity_user_id(auth_id)
        await verify_conversation_ownership(conversation_id, user_id)

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
            for s in request.segments
        ]

        inserted = await append_segments(
            conversation_id=conversation_id,
            user_id=user_id,
            segments=segments_data,
            segment_offset=request.segment_offset,
        )

        total = request.segment_offset + inserted

        print(f"[OMI Router] Appended {inserted} segments to {conversation_id} (total: {total})")

        return AppendSegmentsResponse(inserted=inserted, total_segments=total)

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Failed to append segments: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to append segments: {str(e)}")


@router.post("/conversations/{conversation_id}/finalize", response_model=FinalizeConversationResponse, deprecated=True)
async def finalize_conversation_endpoint(
    conversation_id: str,
    request: FinalizeConversationRequest,
    response: Response,
    auth_id: str = Depends(get_auth_user_id),
):
    """
    Finalize a draft conversation.

    **Deprecated**: Use POST /conversations/store-and-process instead.
    """
    response.headers["Deprecation"] = "true"
    response.headers["Sunset"] = "2026-06-01"
    response.headers["Link"] = '</v1/omi/conversations/store-and-process>; rel="successor-version"'

    try:
        user_id = await resolve_maity_user_id(auth_id)
        conv = await verify_conversation_ownership(conversation_id, user_id)

        # Idempotency guard: if already completed, return existing data
        if conv.get("status") == "completed":
            supabase = get_supabase()
            existing = (
                supabase.schema("maity")
                .table("omi_conversations")
                .select("words_count, duration_seconds, segment_count, embedding")
                .eq("id", conversation_id)
                .single()
                .execute()
            )
            data = existing.data or {}
            print(f"[OMI Router] Finalize idempotent: {conversation_id} already completed")
            return FinalizeConversationResponse(
                id=conversation_id,
                transcript_rebuilt=False,
                words_count=data.get("words_count", 0),
                duration_seconds=data.get("duration_seconds", 0),
                segment_count=data.get("segment_count", 0),
                embedding_generated=data.get("embedding") is not None,
                chunked_processing=False,
            )

        # Prepare structured data
        structured_dict = None
        if request.structured:
            structured_dict = {
                "title": request.structured.title,
                "overview": request.structured.overview,
                "emoji": request.structured.emoji,
                "category": request.structured.category,
                "action_items": request.structured.action_items,
                "events": request.structured.events,
                "discarded": request.structured.discarded,
            }

        # Finalize in DB (rebuilds transcript from segments)
        result = await finalize_conversation(
            conversation_id=conversation_id,
            user_id=user_id,
            structured=structured_dict,
            finished_at=request.finished_at,
        )

        if not result:
            raise HTTPException(status_code=404, detail="Conversation not found or no segments")

        transcript_text = result["transcript_text"]
        words_count = result["words_count"]
        duration_seconds = result["duration_seconds"]
        segment_count = result["segment_count"]
        used_chunked = False

        # Process structured data if not provided by client
        if not request.structured or not request.structured.title:
            print(f"[OMI Router] No structured data provided, using chunked processing ({len(transcript_text)} chars)")
            try:
                chunked_result = await process_long_transcript(transcript_text)
                if chunked_result:
                    used_chunked = True
                    supabase = get_supabase()
                    supabase.schema("maity").table("omi_conversations").update({
                        "title": chunked_result.get("title", "Conversation"),
                        "overview": chunked_result.get("overview", ""),
                        "emoji": chunked_result.get("emoji", ""),
                        "category": chunked_result.get("category", "other"),
                        "action_items": chunked_result.get("action_items", []),
                        "events": chunked_result.get("events", []),
                        "discarded": chunked_result.get("discarded", False),
                    }).eq("id", conversation_id).eq("user_id", user_id).execute()
            except Exception as e:
                print(f"[OMI Router] Chunked processing failed (non-blocking): {e}")

        # Generate embeddings (batch for segments to fix N+1)
        conversation_embedding = None
        if request.generate_embeddings and transcript_text:
            try:
                conversation_embedding = await generate_embedding(transcript_text)
                supabase = get_supabase()
                if conversation_embedding:
                    supabase.schema("maity").table("omi_conversations").update({
                        "embedding": conversation_embedding,
                    }).eq("id", conversation_id).eq("user_id", user_id).execute()

                segments_in_db = result.get("segments", [])
                if segments_in_db:
                    segment_texts = [s.get("text", "") for s in segments_in_db]
                    segment_embeddings = await generate_embeddings_batch(segment_texts)
                    if segment_embeddings:
                        seg_result = (
                            supabase.schema("maity")
                            .table("omi_transcript_segments")
                            .select("id, segment_index")
                            .eq("conversation_id", conversation_id)
                            .eq("user_id", user_id)
                            .order("segment_index")
                            .execute()
                        )
                        if seg_result.data:
                            upsert_rows = []
                            for j, seg_row in enumerate(seg_result.data):
                                if j < len(segment_embeddings) and segment_embeddings[j]:
                                    upsert_rows.append({
                                        "id": seg_row["id"],
                                        "embedding": segment_embeddings[j],
                                    })
                            if upsert_rows:
                                supabase.schema("maity").table("omi_transcript_segments").upsert(
                                    upsert_rows, on_conflict="id",
                                ).execute()
            except Exception as e:
                print(f"[OMI Router] Embedding generation failed (non-blocking): {e}")

        # Pre-filter for auto-discard
        is_discarded = should_auto_discard(words_count, duration_seconds, segment_count)
        if is_discarded:
            supabase = get_supabase()
            supabase.schema("maity").table("omi_conversations").update({
                "discarded": True,
            }).eq("id", conversation_id).eq("user_id", user_id).execute()

        # Communication analysis (non-blocking)
        if not is_discarded:
            try:
                segments_data = result.get("segments", [])
                transcript_segments = [
                    TranscriptSegment(
                        text=s.get("text", ""),
                        speaker=s.get("speaker"),
                        speaker_id=s.get("speaker_id", 0),
                        is_user=s.get("is_user", False),
                        start=s.get("start_time", 0),
                        end=s.get("end_time", 0),
                    )
                    for s in segments_data
                ]
                communication_feedback = await analyze_communication(transcript_segments)
                if communication_feedback:
                    feedback_dict = communication_feedback.model_dump(exclude_none=True)
                    await update_conversation_feedback(
                        conversation_id=conversation_id,
                        user_id=user_id,
                        communication_feedback=feedback_dict,
                    )
            except Exception as e:
                print(f"[OMI Router] Communication analysis failed (non-blocking): {e}")

        # Memory extraction (non-blocking)
        if not is_discarded and transcript_text and len(transcript_text.strip()) >= 50:
            try:
                extracted = await extract_memories_from_transcript(
                    transcript=transcript_text,
                    conversation_id=conversation_id,
                )
                if extracted:
                    supabase = get_supabase()
                    for mem_data in extracted:
                        embedding = await generate_embedding(mem_data.get("content", ""))
                        insert_data = {
                            "user_id": user_id,
                            "auth_id": auth_id,
                            "content": mem_data.get("content"),
                            "category": "interesting",
                            "conversation_id": conversation_id,
                            "reviewed": False,
                            "deleted": False,
                        }
                        if embedding:
                            insert_data["embedding"] = embedding
                        supabase.schema("maity").table("omi_memories").insert(insert_data).execute()
                    print(f"[OMI Router] Extracted {len(extracted)} memories for {conversation_id}")
            except Exception as e:
                print(f"[OMI Router] Memory extraction failed (non-blocking): {e}")

        return FinalizeConversationResponse(
            id=conversation_id,
            transcript_rebuilt=True,
            words_count=words_count,
            duration_seconds=duration_seconds,
            segment_count=segment_count,
            embedding_generated=conversation_embedding is not None,
            chunked_processing=used_chunked,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Failed to finalize conversation: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to finalize: {str(e)}")


@router.post("/conversations/store", response_model=StoreConversationResponse)
async def store_conversation(
    request: StoreConversationRequest,
    auth_id: str = Depends(get_auth_user_id),
):
    """Store a processed conversation with embeddings in Supabase."""
    if not request.transcript_segments:
        raise HTTPException(status_code=400, detail="No transcript segments provided")

    try:
        user_id = await resolve_maity_user_id(auth_id)
        transcript_text = "\n".join([s.text for s in request.transcript_segments])
        words_count = sum(len(s.text.split()) for s in request.transcript_segments)
        duration_seconds = 0
        if request.transcript_segments:
            first = request.transcript_segments[0]
            last = request.transcript_segments[-1]
            if last.end > 0:
                duration_seconds = int(last.end - first.start)

        auto_discard = should_auto_discard(words_count, duration_seconds, len(request.transcript_segments))
        is_discarded = auto_discard or request.structured.discarded

        conversation_embedding = None
        segment_embeddings = None
        if request.generate_embeddings:
            try:
                conversation_embedding = await generate_embedding(transcript_text)
                segment_texts = [s.text for s in request.transcript_segments]
                segment_embeddings = await generate_embeddings_batch(segment_texts)
            except Exception as e:
                print(f"[OMI Router] Embedding generation failed: {e}")

        result = await insert_conversation(
            user_id=user_id,
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
            discarded=is_discarded,
        )

        conversation_id = result["id"]

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
            user_id=user_id,
            segments=segments_data,
            embeddings=segment_embeddings,
        )

        # Communication analysis (non-blocking)
        try:
            transcript_segments = [
                TranscriptSegment(
                    text=s.text, speaker=s.speaker, speaker_id=s.speaker_id,
                    is_user=s.is_user, start=s.start, end=s.end,
                )
                for s in request.transcript_segments
            ]
            communication_feedback = await analyze_communication(transcript_segments)
            if communication_feedback:
                feedback_dict = communication_feedback.model_dump(exclude_none=True)
                await update_conversation_feedback(
                    conversation_id=conversation_id,
                    user_id=user_id,
                    communication_feedback=feedback_dict,
                )
        except Exception as e:
            print(f"[OMI Router] Communication analysis failed (non-blocking): {e}")

        # Memory extraction (non-blocking)
        if not is_discarded and transcript_text and len(transcript_text.strip()) >= 50:
            try:
                extracted = await extract_memories_from_transcript(
                    transcript=transcript_text, conversation_id=conversation_id,
                )
                if extracted:
                    supabase = get_supabase()
                    for mem_data in extracted:
                        embedding = await generate_embedding(mem_data.get("content", ""))
                        insert_data = {
                            "user_id": user_id,
                            "auth_id": auth_id,
                            "content": mem_data.get("content"),
                            "category": "interesting",
                            "conversation_id": conversation_id,
                            "reviewed": False,
                            "deleted": False,
                        }
                        if embedding:
                            insert_data["embedding"] = embedding
                        supabase.schema("maity").table("omi_memories").insert(insert_data).execute()
            except Exception as e:
                print(f"[OMI Router] Memory extraction failed (non-blocking): {e}")

        return StoreConversationResponse(
            id=conversation_id,
            created_at=result["created_at"],
            embedding_generated=conversation_embedding is not None,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Failed to store conversation: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to store conversation: {str(e)}")


@router.post("/conversations/search", response_model=SearchResponse)
async def search_conversations(
    request: SearchRequest,
    auth_id: str = Depends(get_auth_user_id),
):
    """Semantic search for conversations or segments using vector similarity."""
    if not request.query or len(request.query.strip()) < 2:
        return SearchResponse(results=[], query=request.query, count=0)

    user_id = await resolve_maity_user_id(auth_id)

    query_embedding = await generate_embedding(request.query)
    if not query_embedding:
        return SearchResponse(results=[], query=request.query, count=0)

    try:
        if request.search_type == "segments":
            results = await search_segments_by_embedding(
                user_id=user_id,
                query_embedding=query_embedding,
                limit=request.limit,
                similarity_threshold=request.similarity_threshold,
            )
        else:
            results = await search_conversations_by_embedding(
                user_id=user_id,
                query_embedding=query_embedding,
                limit=request.limit,
                similarity_threshold=request.similarity_threshold,
                include_discarded=request.include_discarded,
            )

        return SearchResponse(results=results, query=request.query, count=len(results))

    except Exception as e:
        print(f"[OMI Router] Search failed: {e}")
        return SearchResponse(results=[], query=request.query, count=0)


@router.get("/conversations")
async def list_conversations(
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    include_discarded: bool = Query(False),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """List user's conversations from Supabase."""
    try:
        conversations = await get_conversations(
            user_id=user_id, limit=limit, offset=offset,
            include_discarded=include_discarded,
        )
        return {"conversations": conversations, "count": len(conversations), "limit": limit, "offset": offset}
    except Exception as e:
        print(f"[OMI Router] List conversations failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to fetch conversations: {str(e)}")


@router.get("/conversations/{conversation_id}")
async def get_single_conversation(
    conversation_id: str,
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Get a single conversation with all its transcript segments."""
    try:
        result = await get_conversation_with_segments(user_id=user_id, conversation_id=conversation_id)
        if not result:
            raise HTTPException(status_code=404, detail="Conversation not found")
        return result
    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Get conversation failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to fetch conversation: {str(e)}")


@router.delete("/conversations/{conversation_id}", status_code=204)
async def delete_conversation_endpoint(
    conversation_id: str,
    auth_id: str = Depends(get_auth_user_id),
):
    """Delete a conversation (soft delete - sets deleted=True)."""
    try:
        user_id = await resolve_maity_user_id(auth_id)
        await verify_conversation_ownership(conversation_id, user_id)
        success = await delete_conversation(user_id=user_id, conversation_id=conversation_id)
        if not success:
            raise HTTPException(status_code=404, detail="Conversation not found")
        return Response(status_code=204)
    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Delete conversation failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete conversation: {str(e)}")


@router.patch("/conversations/{conversation_id}/starred")
async def set_conversation_starred(
    conversation_id: str,
    starred: bool = Query(...),
    auth_id: str = Depends(get_auth_user_id),
):
    """Set the starred (favorite) status of a conversation."""
    try:
        user_id = await resolve_maity_user_id(auth_id)
        await verify_conversation_ownership(conversation_id, user_id)
        success = await update_conversation_starred(user_id=user_id, conversation_id=conversation_id, starred=starred)
        if not success:
            raise HTTPException(status_code=404, detail="Conversation not found")
        return {"success": True, "starred": starred}
    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Set conversation starred failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to update starred status: {str(e)}")


@router.patch("/conversations/{conversation_id}/status")
async def update_conversation_status(
    conversation_id: str,
    request: UpdateStatusRequest,
    auth_id: str = Depends(get_auth_user_id),
):
    """Update the status of a conversation."""
    valid_statuses = {"recording", "in_progress", "processing", "completed", "failed"}
    if request.status not in valid_statuses:
        raise HTTPException(status_code=400, detail=f"Invalid status: {request.status}. Valid: {valid_statuses}")

    try:
        user_id = await resolve_maity_user_id(auth_id)
        await verify_conversation_ownership(conversation_id, user_id)

        supabase = get_supabase()
        update_data = {"status": request.status}
        if request.deleted is not None:
            update_data["deleted"] = request.deleted

        supabase.schema("maity").table("omi_conversations").update(
            update_data
        ).eq("id", conversation_id).eq("user_id", user_id).execute()
        return {"id": conversation_id, "status": request.status}
    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Update status failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to update status: {str(e)}")


@router.post("/conversations/{conversation_id}/reprocess")
async def reprocess_conversation(
    conversation_id: str,
    auth_id: str = Depends(get_auth_user_id),
):
    """Reprocess a conversation: rebuild transcript, re-analyze, regenerate embeddings."""
    try:
        user_id = await resolve_maity_user_id(auth_id)
        await verify_conversation_ownership(conversation_id, user_id)

        supabase = get_supabase()

        seg_result = (
            supabase.schema("maity")
            .table("omi_transcript_segments")
            .select("text, speaker_id, is_user, start_time, end_time")
            .eq("conversation_id", conversation_id)
            .order("segment_index")
            .execute()
        )

        segments_in_db = seg_result.data if seg_result.data else []

        if not segments_in_db:
            conv_result = (
                supabase.schema("maity")
                .table("omi_conversations")
                .select("transcript_text")
                .eq("id", conversation_id)
                .eq("user_id", user_id)
                .single()
                .execute()
            )
            if not conv_result.data or not conv_result.data.get("transcript_text"):
                raise HTTPException(status_code=404, detail="No segments or transcript found")
            transcript_text = conv_result.data["transcript_text"]
        else:
            transcript_text = "\n".join([s.get("text", "") for s in segments_in_db])

        words_count = len(transcript_text.split())
        print(f"[OMI Router] Reprocessing conversation {conversation_id}: {len(transcript_text)} chars")

        structured = await process_long_transcript(transcript_text)
        if not structured:
            raise HTTPException(status_code=500, detail="Processing failed")

        embedding = await generate_embedding(transcript_text)

        duration_seconds = 0
        if segments_in_db:
            first = segments_in_db[0]
            last = segments_in_db[-1]
            end_time = last.get("end_time", 0)
            start_time = first.get("start_time", 0)
            if end_time > 0:
                duration_seconds = int(end_time - start_time)

        update_data = {
            "title": structured.get("title", "Conversation"),
            "overview": structured.get("overview", ""),
            "emoji": structured.get("emoji", ""),
            "category": structured.get("category", "other"),
            "action_items": structured.get("action_items", []),
            "events": structured.get("events", []),
            "discarded": structured.get("discarded", False),
            "transcript_text": transcript_text,
            "words_count": words_count,
            "duration_seconds": duration_seconds,
        }
        if embedding:
            update_data["embedding"] = embedding

        supabase.schema("maity").table("omi_conversations").update(
            update_data
        ).eq("id", conversation_id).eq("user_id", user_id).execute()

        # Delete existing memories before re-extracting (fix duplicate memories)
        try:
            supabase.schema("maity").table("omi_memories").delete().eq(
                "conversation_id", conversation_id
            ).eq("user_id", user_id).execute()
            print(f"[OMI Router] Deleted existing memories for {conversation_id}")
        except Exception as e:
            print(f"[OMI Router] Failed to delete existing memories (non-blocking): {e}")

        # Re-extract memories
        try:
            if len(transcript_text.strip()) >= 50:
                extracted = await extract_memories_from_transcript(
                    transcript=transcript_text, conversation_id=conversation_id,
                )
                if extracted:
                    for mem_data in extracted:
                        mem_embedding = await generate_embedding(mem_data.get("content", ""))
                        insert_data = {
                            "user_id": user_id,
                            "auth_id": auth_id,
                            "content": mem_data.get("content"),
                            "category": "interesting",
                            "conversation_id": conversation_id,
                            "reviewed": False,
                            "deleted": False,
                        }
                        if mem_embedding:
                            insert_data["embedding"] = mem_embedding
                        supabase.schema("maity").table("omi_memories").insert(insert_data).execute()
                    print(f"[OMI Router] Re-extracted {len(extracted)} memories")
        except Exception as e:
            print(f"[OMI Router] Memory re-extraction failed (non-blocking): {e}")

        return {
            "success": True,
            "id": conversation_id,
            "title": structured.get("title"),
            "overview": structured.get("overview"),
            "words_count": words_count,
            "duration_seconds": duration_seconds,
            "embedding_generated": embedding is not None,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Reprocess failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to reprocess: {str(e)}")


@router.post("/conversations/cleanup-orphans")
async def cleanup_orphan_drafts(
    auth_id: str = Depends(get_auth_user_id),
):
    """
    Find and finalize orphan draft conversations (status='recording' with
    last_segment_at older than 1 hour).

    Drafts with segments are finalized into completed conversations.
    Drafts without segments are marked as failed + deleted.
    """
    from datetime import timedelta

    try:
        user_id = await resolve_maity_user_id(auth_id)
        supabase = get_supabase()
        cutoff = (datetime.utcnow() - timedelta(hours=1)).isoformat()

        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, last_segment_at, segment_count, created_at")
            .eq("user_id", user_id)
            .eq("status", "recording")
            .lt("last_segment_at", cutoff)
            .execute()
        )
        orphans = result.data if result.data else []

        null_result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, last_segment_at, segment_count, created_at")
            .eq("user_id", user_id)
            .eq("status", "recording")
            .is_("last_segment_at", "null")
            .lt("created_at", cutoff)
            .execute()
        )
        if null_result.data:
            orphans.extend(null_result.data)

        if not orphans:
            return {"cleaned": 0, "finalized": [], "failed": []}

        finalized = []
        failed_list = []

        for orphan in orphans:
            orphan_id = orphan["id"]
            seg_count = orphan.get("segment_count", 0) or 0

            if seg_count > 0:
                try:
                    conv = await finalize_conversation(
                        conversation_id=orphan_id,
                        user_id=user_id,
                        finished_at=datetime.utcnow(),
                    )
                    if conv:
                        transcript_text = conv.get("transcript_text", "")
                        if transcript_text and len(transcript_text.strip()) >= 50:
                            try:
                                chunked_result = await process_long_transcript(transcript_text)
                                if chunked_result:
                                    supabase.schema("maity").table("omi_conversations").update({
                                        "title": chunked_result.get("title", "Conversation"),
                                        "overview": chunked_result.get("overview", ""),
                                        "emoji": chunked_result.get("emoji", ""),
                                        "category": chunked_result.get("category", "other"),
                                        "action_items": chunked_result.get("action_items", []),
                                        "events": chunked_result.get("events", []),
                                        "discarded": chunked_result.get("discarded", False),
                                    }).eq("id", orphan_id).eq("user_id", user_id).execute()
                            except Exception as e:
                                print(f"[OMI Router] Orphan {orphan_id}: structured failed: {e}")

                            try:
                                emb = await generate_embedding(transcript_text)
                                if emb:
                                    supabase.schema("maity").table("omi_conversations").update({
                                        "embedding": emb,
                                    }).eq("id", orphan_id).eq("user_id", user_id).execute()
                            except Exception as e:
                                print(f"[OMI Router] Orphan {orphan_id}: embedding failed: {e}")

                        finalized.append(orphan_id)
                        print(f"[OMI Router] Finalized orphan draft {orphan_id} ({seg_count} segments)")
                    else:
                        supabase.schema("maity").table("omi_conversations").update({
                            "status": "failed",
                            "deleted": True,
                        }).eq("id", orphan_id).eq("user_id", user_id).execute()
                        failed_list.append(orphan_id)
                except Exception as e:
                    print(f"[OMI Router] Failed to finalize orphan {orphan_id}: {e}")
            else:
                supabase.schema("maity").table("omi_conversations").update({
                    "status": "failed",
                    "deleted": True,
                }).eq("id", orphan_id).eq("user_id", user_id).execute()
                failed_list.append(orphan_id)
                print(f"[OMI Router] Marked orphan draft {orphan_id} as failed+deleted (no segments)")

        return {
            "cleaned": len(finalized) + len(failed_list),
            "finalized": finalized,
            "failed": failed_list,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] Cleanup orphans failed: {e}")
        raise HTTPException(status_code=500, detail=f"Cleanup failed: {str(e)}")


@router.post("/conversations/cleanup-processing-orphans")
async def cleanup_processing_orphans(
    authorization: str = Header(...),
):
    """
    Find conversations stuck in 'processing' status for more than 30 minutes
    and mark them as 'failed'.

    Called by Vercel cron job. Requires CRON_SECRET in Authorization header.
    """
    import os
    from datetime import timedelta, timezone

    cron_secret = os.getenv("CRON_SECRET")
    if not cron_secret:
        raise HTTPException(status_code=500, detail="CRON_SECRET not configured")

    token = authorization.replace("Bearer ", "") if authorization.startswith("Bearer ") else authorization
    if token != cron_secret:
        raise HTTPException(status_code=401, detail="Invalid cron secret")

    try:
        supabase = get_supabase()
        cutoff = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()

        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, user_id, created_at")
            .eq("status", "processing")
            .lt("created_at", cutoff)
            .execute()
        )
        orphans = result.data if result.data else []

        if not orphans:
            print("[OMI Router] cleanup-processing-orphans: no orphans found")
            return {"cleaned": 0, "conversation_ids": []}

        cleaned_ids = []
        for orphan in orphans:
            orphan_id = orphan["id"]
            try:
                supabase.schema("maity").table("omi_conversations").update({
                    "status": "failed",
                }).eq("id", orphan_id).execute()
                cleaned_ids.append(orphan_id)
                print(f"[OMI Router] Marked processing orphan {orphan_id} as failed (created_at: {orphan.get('created_at')})")
            except Exception as e:
                print(f"[OMI Router] Failed to update processing orphan {orphan_id}: {e}")

        print(f"[OMI Router] cleanup-processing-orphans: cleaned {len(cleaned_ids)} conversations")
        return {"cleaned": len(cleaned_ids), "conversation_ids": cleaned_ids}

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] cleanup-processing-orphans failed: {e}")
        raise HTTPException(status_code=500, detail=f"Cleanup failed: {str(e)}")


# ============ New Combined Endpoint ============


@router.post("/conversations/store-and-process", response_model=StoreAndProcessResponse)
async def store_and_process_conversation(
    request: StoreAndProcessRequest,
    auth_id: str = Depends(get_auth_user_id),
):
    """
    Store and process a conversation in a single call.

    Replaces the 3-step draft -> segments -> finalize flow.
    """
    if not request.segments:
        raise HTTPException(status_code=400, detail="No segments provided")

    try:
        user_id = await resolve_maity_user_id(auth_id)
        supabase = get_supabase()

        # Idempotency check: if a key is provided, look for an existing conversation
        if request.idempotency_key:
            existing_result = (
                supabase.schema("maity")
                .table("omi_conversations")
                .select("id, status, title, emoji, category, overview, discarded, words_count, duration_seconds, segment_count")
                .eq("user_id", user_id)
                .eq("idempotency_key", request.idempotency_key)
                .limit(1)
                .execute()
            )
            if existing_result.data:
                existing = existing_result.data[0]
                existing_status = existing.get("status", "")
                if existing_status == "completed":
                    print(f"[OMI Router] Idempotent hit: conversation {existing['id']} already completed for key {request.idempotency_key}")
                    return StoreAndProcessResponse(
                        id=existing["id"],
                        title=existing.get("title", ""),
                        emoji=existing.get("emoji", ""),
                        category=existing.get("category", "other"),
                        overview=existing.get("overview", ""),
                        discarded=existing.get("discarded", False),
                        words_count=existing.get("words_count", 0),
                        duration_seconds=existing.get("duration_seconds", 0),
                        segment_count=existing.get("segment_count", 0),
                        embedding_generated=True,
                        chunked_processing=False,
                    )
                elif existing_status == "processing":
                    print(f"[OMI Router] Idempotent hit: conversation {existing['id']} still processing for key {request.idempotency_key}")
                    raise HTTPException(
                        status_code=202,
                        detail=f"Conversation {existing['id']} is still processing",
                        headers={"X-Conversation-Id": existing["id"]},
                    )
                # If status is 'failed', allow re-processing by falling through

        transcript_text = "\n".join([s.text for s in request.segments])
        words_count = sum(len(s.text.split()) for s in request.segments)
        duration_seconds = 0
        if request.segments:
            first = request.segments[0]
            last = request.segments[-1]
            if last.end > 0:
                duration_seconds = int(last.end - first.start)
        segment_count = len(request.segments)

        auto_discard = should_auto_discard(words_count, duration_seconds, segment_count)
        structured_discarded = request.structured.discarded if request.structured else False
        is_discarded = auto_discard or structured_discarded

        conversation_id = str(uuid4())
        title = request.structured.title if request.structured else "Processing..."
        overview = request.structured.overview if request.structured else ""
        emoji = request.structured.emoji if request.structured else ""
        category = request.structured.category if request.structured else "other"

        conv_data = {
            "id": conversation_id,
            "user_id": user_id,
            "title": title,
            "overview": overview,
            "emoji": emoji,
            "category": category,
            "action_items": request.structured.action_items if request.structured else [],
            "events": request.structured.events if request.structured else [],
            "transcript_text": transcript_text,
            "words_count": words_count,
            "duration_seconds": duration_seconds,
            "started_at": request.started_at.isoformat(),
            "finished_at": request.finished_at.isoformat(),
            "source": request.source,
            "language": request.language,
            "status": "processing",
            "discarded": is_discarded,
            "deleted": False,
            "segment_count": segment_count,
        }
        if request.idempotency_key:
            conv_data["idempotency_key"] = request.idempotency_key
        supabase.schema("maity").table("omi_conversations").insert(conv_data).execute()

        # Insert all segments in batch
        segment_rows = []
        for i, s in enumerate(request.segments):
            segment_rows.append({
                "id": str(uuid4()),
                "conversation_id": conversation_id,
                "user_id": user_id,
                "segment_index": i,
                "text": s.text,
                "speaker": s.speaker,
                "speaker_id": s.speaker_id,
                "is_user": s.is_user,
                "person_id": s.person_id,
                "start_time": s.start,
                "end_time": s.end,
            })
        if segment_rows:
            supabase.schema("maity").table("omi_transcript_segments").insert(segment_rows).execute()

        # Process structured data if not provided
        used_chunked = False
        if not request.structured or not request.structured.title:
            try:
                chunked_result = await process_long_transcript(transcript_text)
                if chunked_result:
                    used_chunked = True
                    title = chunked_result.get("title", "Conversation")
                    overview = chunked_result.get("overview", "")
                    emoji = chunked_result.get("emoji", "")
                    category = chunked_result.get("category", "other")
                    is_discarded = is_discarded or chunked_result.get("discarded", False)
                    supabase.schema("maity").table("omi_conversations").update({
                        "title": title,
                        "overview": overview,
                        "emoji": emoji,
                        "category": category,
                        "action_items": chunked_result.get("action_items", []),
                        "events": chunked_result.get("events", []),
                        "discarded": is_discarded,
                    }).eq("id", conversation_id).eq("user_id", user_id).execute()
            except Exception as e:
                print(f"[OMI Router] store-and-process: chunked processing failed: {e}")

        # Generate embeddings (batch)
        conversation_embedding = None
        if request.generate_embeddings and transcript_text:
            try:
                conversation_embedding = await generate_embedding(transcript_text)
                if conversation_embedding:
                    supabase.schema("maity").table("omi_conversations").update({
                        "embedding": conversation_embedding,
                    }).eq("id", conversation_id).eq("user_id", user_id).execute()

                segment_texts = [s.text for s in request.segments]
                segment_embeddings = await generate_embeddings_batch(segment_texts)
                if segment_embeddings:
                    upsert_rows = []
                    for j, seg_row in enumerate(segment_rows):
                        if j < len(segment_embeddings) and segment_embeddings[j]:
                            upsert_rows.append({
                                "id": seg_row["id"],
                                "embedding": segment_embeddings[j],
                            })
                    if upsert_rows:
                        supabase.schema("maity").table("omi_transcript_segments").upsert(
                            upsert_rows, on_conflict="id",
                        ).execute()
            except Exception as e:
                print(f"[OMI Router] store-and-process: embedding failed: {e}")

        # Communication analysis (non-blocking)
        if not is_discarded:
            try:
                transcript_segments = [
                    TranscriptSegment(
                        text=s.text, speaker=s.speaker, speaker_id=s.speaker_id,
                        is_user=s.is_user, start=s.start, end=s.end,
                    )
                    for s in request.segments
                ]
                communication_feedback = await analyze_communication(transcript_segments)
                if communication_feedback:
                    feedback_dict = communication_feedback.model_dump(exclude_none=True)
                    await update_conversation_feedback(
                        conversation_id=conversation_id,
                        user_id=user_id,
                        communication_feedback=feedback_dict,
                    )
            except Exception as e:
                print(f"[OMI Router] store-and-process: communication analysis failed: {e}")

        # Memory extraction (non-blocking)
        if not is_discarded and transcript_text and len(transcript_text.strip()) >= 50:
            try:
                extracted = await extract_memories_from_transcript(
                    transcript=transcript_text, conversation_id=conversation_id,
                )
                if extracted:
                    for mem_data in extracted:
                        emb = await generate_embedding(mem_data.get("content", ""))
                        insert_data = {
                            "user_id": user_id,
                            "auth_id": auth_id,
                            "content": mem_data.get("content"),
                            "category": "interesting",
                            "conversation_id": conversation_id,
                            "reviewed": False,
                            "deleted": False,
                        }
                        if emb:
                            insert_data["embedding"] = emb
                        supabase.schema("maity").table("omi_memories").insert(insert_data).execute()
                    print(f"[OMI Router] store-and-process: extracted {len(extracted)} memories")
            except Exception as e:
                print(f"[OMI Router] store-and-process: memory extraction failed: {e}")

        # Set final status to completed
        supabase.schema("maity").table("omi_conversations").update({
            "status": "completed",
        }).eq("id", conversation_id).eq("user_id", user_id).execute()

        return StoreAndProcessResponse(
            id=conversation_id,
            title=title,
            emoji=emoji,
            category=category,
            overview=overview,
            discarded=is_discarded,
            words_count=words_count,
            duration_seconds=duration_seconds,
            segment_count=segment_count,
            embedding_generated=conversation_embedding is not None,
            chunked_processing=used_chunked,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[OMI Router] store-and-process failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to store and process: {str(e)}")
