"""Conversations router - Process and list conversations"""
from datetime import datetime
from typing import List, Optional
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Query

from ..models.conversation import (
    ProcessConversationRequest,
    ProcessConversationResponse,
    TranscriptSegment,
    ConversationMetrics,
)
from ..services.openai_processor import (
    process_conversation as openai_process,
    count_words,
    calculate_duration,
    count_insights,
)
from ..services.firebase_client import (
    save_conversation,
    get_user_conversations,
)


router = APIRouter(prefix="/v1/conversations", tags=["conversations"])


@router.post("/process", response_model=ProcessConversationResponse)
async def process_conversation(request: ProcessConversationRequest):
    """
    Process a conversation transcript.

    Takes raw transcript segments and:
    1. Generates title, emoji, overview using OpenAI
    2. Extracts category, action items, events
    3. Calculates metrics
    4. Saves to Firestore

    Returns the processed conversation with all structured data.
    """
    if not request.transcript_segments:
        raise HTTPException(status_code=400, detail="No transcript segments provided")

    # Convert request segments to internal model
    segments = [
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

    # Process with OpenAI
    structured = await openai_process(segments)

    # Calculate metrics
    words = count_words(segments)
    duration = calculate_duration(segments)
    insights = count_insights(structured)

    metrics = ConversationMetrics(
        words_count=words,
        duration_seconds=duration,
        insights_count=insights,
    )

    # Create conversation response
    conversation = ProcessConversationResponse(
        id=str(uuid4()),
        created_at=datetime.now(),
        started_at=request.started_at,
        finished_at=request.finished_at,
        structured=structured,
        metrics=metrics,
        transcript_segments=segments,
    )

    # Save to Firestore
    try:
        await save_conversation(request.user_id, conversation)
    except Exception as e:
        # Log but don't fail - conversation was processed successfully
        print(f"[Conversations Router] Failed to save to Firestore: {e}")

    return conversation


@router.get("/list")
async def list_conversations(
    user_id: str = Query(..., description="Firebase user ID"),
    limit: int = Query(50, ge=1, le=100, description="Max conversations to return"),
    offset: int = Query(0, ge=0, description="Offset for pagination"),
):
    """
    List user's conversations.

    Returns conversations sorted by creation date (newest first).
    """
    try:
        conversations = await get_user_conversations(user_id, limit, offset)
        return {
            "conversations": conversations,
            "count": len(conversations),
            "limit": limit,
            "offset": offset,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch conversations: {e}")
