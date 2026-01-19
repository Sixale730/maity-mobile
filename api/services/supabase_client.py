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
    similarity_threshold: float = 0.3,
    include_discarded: bool = False,
) -> List[Dict]:
    """
    Search conversations using vector similarity (cosine distance).

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    try:
        print(f"[Supabase] Searching conversations for user: {user_id}")
        print(f"[Supabase] Embedding length: {len(query_embedding)}, threshold: {similarity_threshold}")

        # Use RPC function for vector search
        # Function signature: search_omi_conversations(p_user_id, p_query_embedding, p_limit, p_similarity_threshold, p_include_discarded)
        result = supabase.schema("maity").rpc(
            "search_omi_conversations",
            {
                "p_user_id": user_id,
                "p_query_embedding": query_embedding,
                "p_limit": limit,
                "p_similarity_threshold": similarity_threshold,
                "p_include_discarded": include_discarded,
            },
        ).execute()

        print(f"[Supabase] RPC result count: {len(result.data) if result.data else 0}")

        return result.data if result.data else []
    except Exception as e:
        print(f"[Supabase] RPC search_conversations failed: {e}")
        return []


async def search_segments_by_embedding(
    user_id: str,
    query_embedding: List[float],
    limit: int = 20,
    similarity_threshold: float = 0.3,
) -> List[Dict]:
    """
    Search transcript segments using vector similarity.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
    """
    supabase = get_supabase()

    try:
        print(f"[Supabase] Searching segments for user: {user_id}")

        # Function signature: search_omi_segments(p_user_id, p_query_embedding, p_limit, p_similarity_threshold)
        result = supabase.schema("maity").rpc(
            "search_omi_segments",
            {
                "p_user_id": user_id,
                "p_query_embedding": query_embedding,
                "p_limit": limit,
                "p_similarity_threshold": similarity_threshold,
            },
        ).execute()

        print(f"[Supabase] RPC segments result count: {len(result.data) if result.data else 0}")

        return result.data if result.data else []
    except Exception as e:
        print(f"[Supabase] RPC search_segments failed: {e}")
        return []


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


async def update_conversation_feedback(
    conversation_id: str,
    user_id: str,
    communication_feedback: Dict,
) -> bool:
    """
    Update a conversation with communication feedback.

    Args:
        conversation_id: UUID of the conversation
        user_id: UUID de maity.users (for authorization)
        communication_feedback: Dict with strengths, areas_to_improve, observations, summary
    """
    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .update({"communication_feedback": communication_feedback})
            .eq("id", conversation_id)
            .eq("user_id", user_id)
            .execute()
        )
        return True
    except Exception as e:
        print(f"[Supabase Client] Failed to update communication feedback: {e}")
        return False


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


async def delete_conversation(user_id: str, conversation_id: str) -> bool:
    """
    Soft delete a conversation (set deleted=True).

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        conversation_id: UUID of the conversation to delete

    Returns:
        True if conversation was found and deleted, False otherwise
    """
    supabase = get_supabase()

    # Soft delete: set deleted=True (only if it belongs to the user)
    result = (
        supabase.schema("maity")
        .table("omi_conversations")
        .update({"deleted": True})
        .eq("id", conversation_id)
        .eq("user_id", user_id)
        .execute()
    )

    return len(result.data) > 0 if result.data else False


async def get_user_metrics(
    user_id: str,
    period: str = "monthly",
) -> Dict[str, Any]:
    """
    Get aggregated metrics for a user from Supabase.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        period: today, weekly, monthly, yearly, all

    Returns:
        Dict with aggregated stats and history
    """
    from datetime import timedelta
    from collections import defaultdict

    supabase = get_supabase()

    # Calculate date range
    now = datetime.utcnow()
    if period == "today":
        start_date = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif period == "weekly":
        start_date = now - timedelta(days=7)
    elif period == "monthly":
        start_date = now - timedelta(days=30)
    elif period == "yearly":
        start_date = now - timedelta(days=365)
    else:  # all
        start_date = datetime(2020, 1, 1)

    start_iso = start_date.isoformat()

    try:
        # Query conversations for the period
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("duration_seconds, words_count, action_items, events, category, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .gte("created_at", start_iso)
            .order("created_at", desc=True)
            .execute()
        )

        conversations = result.data if result.data else []

        # Aggregate stats
        total_seconds = 0
        total_words = 0
        total_conversations = len(conversations)
        total_insights = 0
        category_counts: Dict[str, int] = defaultdict(int)
        daily_data: Dict[str, Dict[str, Any]] = defaultdict(
            lambda: {"conversations": 0, "minutes": 0.0, "words": 0}
        )

        for conv in conversations:
            duration = conv.get("duration_seconds") or 0
            words = conv.get("words_count") or 0
            action_items = conv.get("action_items") or []
            events = conv.get("events") or []
            category = conv.get("category") or "other"
            created_at = conv.get("created_at", "")

            total_seconds += duration
            total_words += words
            total_insights += len(action_items) + len(events)
            category_counts[category] += 1

            # Aggregate by date
            if created_at:
                date_key = created_at[:10]  # YYYY-MM-DD
                daily_data[date_key]["conversations"] += 1
                daily_data[date_key]["minutes"] += duration / 60
                daily_data[date_key]["words"] += words

        # Build top categories
        top_categories = sorted(
            [{"category": cat, "count": count} for cat, count in category_counts.items()],
            key=lambda x: x["count"],
            reverse=True,
        )[:10]

        # Build history (last 30 days max)
        history = sorted(
            [
                {
                    "date": date,
                    "conversations": d["conversations"],
                    "minutes": round(d["minutes"], 1),
                    "words": d["words"],
                }
                for date, d in daily_data.items()
            ],
            key=lambda x: x["date"],
            reverse=True,
        )[:30]

        return {
            "period": period,
            "user_id": user_id,
            "stats": {
                "transcription_seconds": total_seconds,
                "words_transcribed": total_words,
                "conversations_count": total_conversations,
                "insights_gained": total_insights,
                "top_categories": top_categories,
            },
            "history": history,
        }

    except Exception as e:
        print(f"[Supabase] Error getting user metrics: {e}")
        return {
            "period": period,
            "user_id": user_id,
            "stats": {
                "transcription_seconds": 0,
                "words_transcribed": 0,
                "conversations_count": 0,
                "insights_gained": 0,
                "top_categories": [],
            },
            "history": [],
        }
