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
    discarded: bool = False,
) -> Dict[str, Any]:
    """
    Insert a conversation into maity.omi_conversations.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        discarded: If True, the conversation is marked as banal/irrelevant
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
        "discarded": discarded,
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


async def insert_draft_conversation(
    user_id: str,
    started_at: datetime,
    source: str = "omi",
) -> Dict[str, Any]:
    """
    Insert a draft conversation with status='recording'.

    This creates a placeholder row that segments will be appended to
    during incremental saving.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        started_at: When recording started
        source: Conversation source (omi, phone, desktop)

    Returns:
        Dict with id and created_at
    """
    supabase = get_supabase()

    conversation_id = str(uuid4())

    data = {
        "id": conversation_id,
        "user_id": user_id,
        "title": "Recording...",
        "overview": "",
        "emoji": "🎙️",
        "category": "other",
        "action_items": [],
        "events": [],
        "transcript_text": "",
        "words_count": 0,
        "duration_seconds": 0,
        "started_at": started_at.isoformat(),
        "finished_at": started_at.isoformat(),
        "source": source,
        "status": "recording",
        "discarded": False,
        "deleted": False,
        "segment_count": 0,
    }

    supabase.schema("maity").table("omi_conversations").insert(data).execute()

    return {"id": conversation_id, "created_at": datetime.utcnow().isoformat()}


async def append_segments(
    conversation_id: str,
    user_id: str,
    segments: List[Dict],
    segment_offset: int = 0,
) -> int:
    """
    Append segments to a draft conversation using upsert (ON CONFLICT DO NOTHING).

    Idempotent: re-sending the same segments is safe thanks to unique index
    on (conversation_id, segment_index).

    Args:
        conversation_id: UUID of the draft conversation
        user_id: UUID de maity.users
        segments: List of segment dicts with text, speaker, etc.
        segment_offset: Starting index for segment_index

    Returns:
        Number of segments inserted
    """
    supabase = get_supabase()

    rows = []
    for i, segment in enumerate(segments):
        row = {
            "id": str(uuid4()),
            "conversation_id": conversation_id,
            "user_id": user_id,
            "segment_index": segment_offset + i,
            "text": segment.get("text", ""),
            "speaker": segment.get("speaker"),
            "speaker_id": segment.get("speaker_id", 0),
            "is_user": segment.get("is_user", False),
            "person_id": segment.get("person_id"),
            "start_time": segment.get("start", 0.0),
            "end_time": segment.get("end", 0.0),
        }
        rows.append(row)

    if rows:
        # Upsert with ON CONFLICT DO NOTHING on (conversation_id, segment_index)
        supabase.schema("maity").table("omi_transcript_segments").upsert(
            rows,
            on_conflict="conversation_id,segment_index",
            ignore_duplicates=True,
        ).execute()

        # Update conversation metadata
        now = datetime.utcnow()
        supabase.schema("maity").table("omi_conversations").update({
            "last_segment_at": now.isoformat(),
            "segment_count": segment_offset + len(rows),
        }).eq("id", conversation_id).eq("user_id", user_id).execute()

    return len(rows)


async def finalize_conversation(
    conversation_id: str,
    user_id: str,
    structured: Optional[Dict] = None,
    finished_at: Optional[datetime] = None,
) -> Optional[Dict[str, Any]]:
    """
    Finalize a draft conversation: rebuild transcript from segments in DB,
    update structured data, generate embeddings, and set status to 'completed'.

    The transcript is rebuilt from segments stored in the DB (not from client)
    to ensure we have all incrementally saved segments even if the client
    lost some in RAM.

    Args:
        conversation_id: UUID of the draft conversation
        user_id: UUID de maity.users
        structured: Optional structured data (title, overview, etc.)
        finished_at: When recording ended

    Returns:
        Dict with conversation data or None if not found
    """
    supabase = get_supabase()

    # Step 1: Read all segments from DB to rebuild transcript
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
        print(f"[Supabase Client] No segments found for conversation {conversation_id}")
        return None

    # Rebuild transcript_text from segments in DB
    transcript_text = "\n".join([s.get("text", "") for s in segments_in_db])
    words_count = sum(len(s.get("text", "").split()) for s in segments_in_db)

    # Calculate duration from segment timestamps
    duration_seconds = 0
    if segments_in_db:
        first = segments_in_db[0]
        last = segments_in_db[-1]
        end_time = last.get("end_time", 0)
        start_time = first.get("start_time", 0)
        if end_time > 0:
            duration_seconds = int(end_time - start_time)

    # Build update data
    update_data = {
        "status": "completed",
        "transcript_text": transcript_text,
        "words_count": words_count,
        "duration_seconds": duration_seconds,
        "segment_count": len(segments_in_db),
    }

    if finished_at:
        update_data["finished_at"] = finished_at.isoformat()

    if structured:
        update_data["title"] = structured.get("title", "Conversation")
        update_data["overview"] = structured.get("overview", "")
        update_data["emoji"] = structured.get("emoji", "🎤")
        update_data["category"] = structured.get("category", "other")
        update_data["action_items"] = structured.get("action_items", [])
        update_data["events"] = structured.get("events", [])
        update_data["discarded"] = structured.get("discarded", False)

    # Step 2: Update the conversation row
    result = (
        supabase.schema("maity")
        .table("omi_conversations")
        .update(update_data)
        .eq("id", conversation_id)
        .eq("user_id", user_id)
        .execute()
    )

    if not result.data:
        print(f"[Supabase Client] Conversation {conversation_id} not found for user {user_id}")
        return None

    return {
        "id": conversation_id,
        "transcript_text": transcript_text,
        "words_count": words_count,
        "duration_seconds": duration_seconds,
        "segment_count": len(segments_in_db),
        "segments": segments_in_db,
    }


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
        .eq("status", "completed")
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


async def update_conversation_starred(
    user_id: str,
    conversation_id: str,
    starred: bool,
) -> bool:
    """
    Update the starred status of a conversation.

    Args:
        user_id: UUID de maity.users (for authorization)
        conversation_id: UUID of the conversation
        starred: New starred status

    Returns:
        True if conversation was found and updated, False otherwise
    """
    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .update({"starred": starred})
            .eq("id", conversation_id)
            .eq("user_id", user_id)
            .execute()
        )
        return len(result.data) > 0 if result.data else False
    except Exception as e:
        print(f"[Supabase Client] Failed to update starred status: {e}")
        return False


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

        # Query memories for the period
        memories_result = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("id, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .gte("created_at", start_iso)
            .execute()
        )

        memories = memories_result.data if memories_result.data else []

        # Aggregate stats
        total_seconds = 0
        total_words = 0
        total_conversations = len(conversations)
        total_insights = 0
        total_memories = len(memories)
        category_counts: Dict[str, int] = defaultdict(int)
        daily_data: Dict[str, Dict[str, Any]] = defaultdict(
            lambda: {"conversations": 0, "minutes": 0.0, "words": 0, "insights": 0, "memories": 0}
        )

        for conv in conversations:
            duration = conv.get("duration_seconds") or 0
            words = conv.get("words_count") or 0
            action_items = conv.get("action_items") or []
            events = conv.get("events") or []
            category = conv.get("category") or "other"
            created_at = conv.get("created_at", "")

            insights_count = len(action_items) + len(events)
            total_seconds += duration
            total_words += words
            total_insights += insights_count
            category_counts[category] += 1

            # Aggregate by date
            if created_at:
                date_key = created_at[:10]  # YYYY-MM-DD
                daily_data[date_key]["conversations"] += 1
                daily_data[date_key]["minutes"] += duration / 60
                daily_data[date_key]["words"] += words
                daily_data[date_key]["insights"] += insights_count

        # Aggregate memories by date
        for memory in memories:
            created_at = memory.get("created_at", "")
            if created_at:
                date_key = created_at[:10]  # YYYY-MM-DD
                daily_data[date_key]["memories"] += 1

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
                    "insights": d["insights"],
                    "memories": d["memories"],
                }
                for date, d in daily_data.items()
            ],
            key=lambda x: x["date"],
            reverse=True,
        )[:30]

        return {
            "success": True,
            "error": None,
            "period": period,
            "user_id": user_id,
            "stats": {
                "transcription_seconds": total_seconds,
                "words_transcribed": total_words,
                "conversations_count": total_conversations,
                "insights_gained": total_insights,
                "memories_count": total_memories,
                "top_categories": top_categories,
            },
            "history": history,
        }

    except Exception as e:
        print(f"[Supabase] Error getting user metrics: {e}")
        return {
            "success": False,
            "error": f"Error al obtener métricas de uso: {str(e)}",
            "period": period,
            "user_id": user_id,
            "stats": {
                "transcription_seconds": 0,
                "words_transcribed": 0,
                "conversations_count": 0,
                "insights_gained": 0,
                "memories_count": 0,
                "top_categories": [],
            },
            "history": [],
        }


async def get_day_summary(
    user_id: str,
    fecha: str = None,
) -> Dict[str, Any]:
    """
    Get a complete summary of a specific day including conversations,
    metrics, action items, and events.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        fecha: Date in YYYY-MM-DD format. Defaults to today.
    """
    from collections import defaultdict

    supabase = get_supabase()

    if not fecha:
        fecha = datetime.utcnow().strftime("%Y-%m-%d")

    # Date range for the day
    start_date = f"{fecha}T00:00:00"
    end_date = f"{fecha}T23:59:59"

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, overview, emoji, category, duration_seconds, words_count, action_items, events, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .gte("created_at", start_date)
            .lte("created_at", end_date)
            .order("created_at", desc=True)
            .execute()
        )

        conversations = result.data if result.data else []

        # Aggregate metrics
        total_duration = 0
        total_words = 0
        all_action_items = []
        all_events = []
        category_counts: Dict[str, int] = defaultdict(int)

        for conv in conversations:
            total_duration += conv.get("duration_seconds") or 0
            total_words += conv.get("words_count") or 0

            # Extract action items with conversation context
            for item in (conv.get("action_items") or []):
                all_action_items.append({
                    "description": item.get("description", ""),
                    "completed": item.get("completed", False),
                    "conversation_title": conv.get("title"),
                    "conversation_emoji": conv.get("emoji"),
                    "conversation_id": conv.get("id"),
                })

            # Extract events
            for event in (conv.get("events") or []):
                all_events.append({
                    "title": event.get("title", ""),
                    "start": event.get("start"),
                    "end": event.get("end"),
                    "conversation_title": conv.get("title"),
                })

            category = conv.get("category") or "other"
            category_counts[category] += 1

        # Format conversations for response
        formatted_convs = [
            {
                "id": c.get("id"),
                "title": c.get("title"),
                "overview": c.get("overview"),
                "emoji": c.get("emoji"),
                "category": c.get("category"),
                "duration_seconds": c.get("duration_seconds"),
                "created_at": c.get("created_at"),
            }
            for c in conversations
        ]

        return {
            "success": True,
            "error": None,
            "fecha": fecha,
            "conversaciones": formatted_convs,
            "total_conversaciones": len(conversations),
            "duracion_total_segundos": total_duration,
            "duracion_total_minutos": round(total_duration / 60, 1),
            "palabras_totales": total_words,
            "action_items": all_action_items,
            "eventos": all_events,
            "categorias": dict(category_counts),
        }

    except Exception as e:
        print(f"[Supabase] Error getting day summary: {e}")
        return {
            "success": False,
            "error": f"Error al obtener resumen del día: {str(e)}",
            "fecha": fecha,
            "conversaciones": [],
            "total_conversaciones": 0,
            "duracion_total_segundos": 0,
            "duracion_total_minutos": 0,
            "palabras_totales": 0,
            "action_items": [],
            "eventos": [],
            "categorias": {},
        }


async def get_action_items(
    user_id: str,
    fecha_inicio: str = None,
    fecha_fin: str = None,
    texto_busqueda: str = None,
    limite: int = 20,
) -> Dict[str, Any]:
    """
    Get action items from conversations within a date range.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        fecha_inicio: Start date YYYY-MM-DD. Defaults to 7 days ago.
        fecha_fin: End date YYYY-MM-DD. Defaults to today.
        texto_busqueda: Optional text to filter action items.
        limite: Max number of action items to return.
    """
    supabase = get_supabase()

    now = datetime.utcnow()
    if not fecha_fin:
        fecha_fin = now.strftime("%Y-%m-%d")
    if not fecha_inicio:
        fecha_inicio = (now - timedelta(days=7)).strftime("%Y-%m-%d")

    start_date = f"{fecha_inicio}T00:00:00"
    end_date = f"{fecha_fin}T23:59:59"

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, emoji, action_items, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .gte("created_at", start_date)
            .lte("created_at", end_date)
            .order("created_at", desc=True)
            .execute()
        )

        conversations = result.data if result.data else []

        # Extract all action items with context
        all_items = []
        for conv in conversations:
            for item in (conv.get("action_items") or []):
                description = item.get("description", "")

                # Filter by search text if provided
                if texto_busqueda and texto_busqueda.lower() not in description.lower():
                    continue

                all_items.append({
                    "description": description,
                    "completed": item.get("completed", False),
                    "conversation_title": conv.get("title"),
                    "conversation_emoji": conv.get("emoji"),
                    "conversation_id": conv.get("id"),
                    "fecha": conv.get("created_at", "")[:10],
                })

                if len(all_items) >= limite:
                    break

            if len(all_items) >= limite:
                break

        # Count pending vs completed
        pendientes = sum(1 for i in all_items if not i["completed"])
        completados = sum(1 for i in all_items if i["completed"])

        return {
            "success": True,
            "error": None,
            "action_items": all_items[:limite],
            "total": len(all_items),
            "pendientes": pendientes,
            "completados": completados,
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
        }

    except Exception as e:
        print(f"[Supabase] Error getting action items: {e}")
        return {
            "success": False,
            "error": f"Error al obtener action items: {str(e)}",
            "action_items": [],
            "total": 0,
            "pendientes": 0,
            "completados": 0,
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
        }


async def search_by_category(
    user_id: str,
    categoria: str,
    fecha_inicio: str = None,
    fecha_fin: str = None,
    limite: int = 10,
) -> Dict[str, Any]:
    """
    Search conversations by category.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        categoria: Category to filter by (e.g., 'work', 'personal')
        fecha_inicio: Optional start date YYYY-MM-DD
        fecha_fin: Optional end date YYYY-MM-DD
        limite: Max conversations to return
    """
    supabase = get_supabase()

    try:
        query = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, overview, emoji, category, duration_seconds, words_count, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .ilike("category", categoria)
        )

        if fecha_inicio:
            query = query.gte("created_at", f"{fecha_inicio}T00:00:00")
        if fecha_fin:
            query = query.lte("created_at", f"{fecha_fin}T23:59:59")

        result = (
            query
            .order("created_at", desc=True)
            .limit(limite)
            .execute()
        )

        conversations = result.data if result.data else []

        # Format response
        formatted = [
            {
                "id": c.get("id"),
                "title": c.get("title"),
                "overview": c.get("overview"),
                "emoji": c.get("emoji"),
                "category": c.get("category"),
                "duration_seconds": c.get("duration_seconds"),
                "words_count": c.get("words_count"),
                "created_at": c.get("created_at"),
            }
            for c in conversations
        ]

        return {
            "success": True,
            "error": None,
            "categoria": categoria,
            "conversaciones": formatted,
            "total": len(formatted),
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
        }

    except Exception as e:
        print(f"[Supabase] Error searching by category: {e}")
        return {
            "success": False,
            "error": f"Error al buscar por categoría: {str(e)}",
            "categoria": categoria,
            "conversaciones": [],
            "total": 0,
        }


async def get_communication_feedback_aggregate(
    user_id: str,
    fecha_inicio: str = None,
    fecha_fin: str = None,
    limite: int = 20,
) -> Dict[str, Any]:
    """
    Aggregate communication feedback from multiple conversations.

    Args:
        user_id: UUID de maity.users (no auth.users.id)
        fecha_inicio: Start date YYYY-MM-DD. Defaults to 30 days ago.
        fecha_fin: End date YYYY-MM-DD. Defaults to today.
        limite: Max conversations to analyze.
    """
    from collections import Counter

    supabase = get_supabase()

    now = datetime.utcnow()
    if not fecha_fin:
        fecha_fin = now.strftime("%Y-%m-%d")
    if not fecha_inicio:
        fecha_inicio = (now - timedelta(days=30)).strftime("%Y-%m-%d")

    start_date = f"{fecha_inicio}T00:00:00"
    end_date = f"{fecha_fin}T23:59:59"

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, communication_feedback, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .gte("created_at", start_date)
            .lte("created_at", end_date)
            .not_.is_("communication_feedback", "null")
            .order("created_at", desc=True)
            .limit(limite)
            .execute()
        )

        conversations = result.data if result.data else []

        # Aggregate feedback
        all_strengths = Counter()
        all_areas_to_improve = Counter()
        total_filler_words: Dict[str, int] = {}
        all_objections_received = []
        all_objections_made = []
        total_pero_count = 0
        conversations_analyzed = 0

        for conv in conversations:
            feedback = conv.get("communication_feedback")
            if not feedback:
                continue

            conversations_analyzed += 1

            # Count strengths
            for strength in (feedback.get("strengths") or []):
                all_strengths[strength] += 1

            # Count areas to improve
            for area in (feedback.get("areas_to_improve") or []):
                all_areas_to_improve[area] += 1

            # Aggregate counters if present
            counters = feedback.get("counters") or {}

            # Filler words
            for word, count in (counters.get("filler_words") or {}).items():
                total_filler_words[word] = total_filler_words.get(word, 0) + count

            # Pero count
            total_pero_count += counters.get("pero_count", 0)

            # Objections
            all_objections_received.extend(counters.get("objections_received") or [])
            all_objections_made.extend(counters.get("objections_made") or [])

        # Get top items
        top_strengths = [s for s, _ in all_strengths.most_common(5)]
        top_areas = [a for a, _ in all_areas_to_improve.most_common(5)]

        # Sort filler words by frequency
        sorted_fillers = dict(sorted(total_filler_words.items(), key=lambda x: x[1], reverse=True))

        return {
            "success": True,
            "error": None,
            "conversaciones_analizadas": conversations_analyzed,
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
            "fortalezas_frecuentes": top_strengths,
            "areas_de_mejora_frecuentes": top_areas,
            "muletillas_totales": sorted_fillers,
            "total_muletillas": sum(total_filler_words.values()),
            "conteo_pero": total_pero_count,
            "objeciones_recibidas": all_objections_received[:10],
            "objeciones_hechas": all_objections_made[:10],
        }

    except Exception as e:
        print(f"[Supabase] Error getting communication feedback: {e}")
        return {
            "success": False,
            "error": f"Error al obtener feedback de comunicación: {str(e)}",
            "conversaciones_analizadas": 0,
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
            "fortalezas_frecuentes": [],
            "areas_de_mejora_frecuentes": [],
            "muletillas_totales": {},
            "total_muletillas": 0,
            "conteo_pero": 0,
            "objeciones_recibidas": [],
            "objeciones_hechas": [],
        }
