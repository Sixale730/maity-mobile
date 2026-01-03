"""Supabase client for OMI conversations storage"""
import os
from typing import List, Optional, Dict, Any
from uuid import uuid4
from datetime import datetime

from supabase import create_client, Client


# Initialize Supabase client with service role key
_supabase: Optional[Client] = None


def get_supabase() -> Client:
    """Get or create Supabase client"""
    global _supabase
    if _supabase is None:
        url = os.getenv("SUPABASE_URL")
        key = os.getenv("SUPABASE_SERVICE_KEY")
        if not url or not key:
            raise ValueError("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set")
        _supabase = create_client(url, key)
    return _supabase


async def insert_conversation(
    user_id: str,
    title: str,
    overview: str,
    emoji: str,
    category: str,
    action_items: List[Dict],
    events: List[Dict],
    transcript_text: str,
    embedding: Optional[List[float]],
    words_count: int,
    duration_seconds: int,
    started_at: datetime,
    finished_at: datetime,
    source: str = "omi",
    language: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Insert a conversation into maity.omi_conversations.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    conversation_id = str(uuid4())

    data = {
        "id": conversation_id,
        "user_id": user_id,
        "title": title,
        "overview": overview,
        "emoji": emoji,
        "category": category,
        "action_items": action_items,
        "events": events,
        "transcript_text": transcript_text,
        "words_count": words_count,
        "duration_seconds": duration_seconds,
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "source": source,
        "language": language,
        "status": "completed",
        "discarded": False,
        "deleted": False,
    }

    # Add embedding if provided (pgvector format)
    if embedding:
        data["embedding"] = embedding

    result = supabase.schema("maity").table("omi_conversations").insert(data).execute()

    return {"id": conversation_id, "created_at": datetime.utcnow().isoformat()}


async def insert_segments(
    conversation_id: str,
    user_id: str,
    segments: List[Dict],
    embeddings: Optional[List[List[float]]] = None,
) -> int:
    """
    Insert transcript segments into maity.omi_transcript_segments.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    rows = []
    for i, segment in enumerate(segments):
        row = {
            "id": str(uuid4()),
            "conversation_id": conversation_id,
            "user_id": user_id,
            "segment_index": i,
            "text": segment.get("text", ""),
            "speaker": segment.get("speaker"),
            "speaker_id": segment.get("speaker_id", 0),
            "is_user": segment.get("is_user", False),
            "person_id": segment.get("person_id"),
            "start_time": segment.get("start", 0.0),
            "end_time": segment.get("end", 0.0),
        }

        # Add embedding if provided
        if embeddings and i < len(embeddings) and embeddings[i]:
            row["embedding"] = embeddings[i]

        rows.append(row)

    if rows:
        supabase.schema("maity").table("omi_transcript_segments").insert(rows).execute()

    return len(rows)


async def search_conversations_by_embedding(
    user_id: str,
    query_embedding: List[float],
    limit: int = 10,
    similarity_threshold: float = 0.7,
    include_discarded: bool = False,
) -> List[Dict]:
    """
    Search conversations using vector similarity (cosine distance).

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    # Use RPC function for vector search
    # Function signature: search_omi_conversations(p_user_id, p_query_embedding, p_limit, p_similarity_threshold, p_include_discarded)
    result = supabase.rpc(
        "search_omi_conversations",
        {
            "p_user_id": user_id,
            "p_query_embedding": query_embedding,
            "p_limit": limit,
            "p_similarity_threshold": similarity_threshold,
            "p_include_discarded": include_discarded,
        },
    ).execute()

    return result.data if result.data else []


async def search_segments_by_embedding(
    user_id: str,
    query_embedding: List[float],
    limit: int = 20,
    similarity_threshold: float = 0.7,
) -> List[Dict]:
    """
    Search transcript segments using vector similarity.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    # Function signature: search_omi_segments(p_user_id, p_query_embedding, p_limit, p_similarity_threshold)
    result = supabase.rpc(
        "search_omi_segments",
        {
            "p_user_id": user_id,
            "p_query_embedding": query_embedding,
            "p_limit": limit,
            "p_similarity_threshold": similarity_threshold,
        },
    ).execute()

    return result.data if result.data else []


async def get_conversations(
    user_id: str,
    limit: int = 50,
    offset: int = 0,
    include_discarded: bool = False,
) -> List[Dict]:
    """
    Get user's conversations ordered by creation date.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    query = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("*")
        .eq("user_id", user_id)
        .eq("deleted", False)
    )

    if not include_discarded:
        query = query.eq("discarded", False)

    result = (
        query
        .order("created_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )

    return result.data if result.data else []


async def get_conversation_with_segments(
    user_id: str,
    conversation_id: str,
) -> Optional[Dict]:
    """
    Get a single conversation with all its segments.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    # Get conversation
    conv_result = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("*")
        .eq("id", conversation_id)
        .eq("user_id", user_id)
        .single()
        .execute()
    )

    if not conv_result.data:
        return None

    # Get segments
    seg_result = (
        supabase.schema("maity")
        .table("omi_transcript_segments")
        .select("*")
        .eq("conversation_id", conversation_id)
        .order("segment_index")
        .execute()
    )

    return {
        "conversation": conv_result.data,
        "segments": seg_result.data if seg_result.data else [],
    }
