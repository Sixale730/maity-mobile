"""Memories router - CRUD operations and extraction for user memories"""
from fastapi import APIRouter, HTTPException, Depends, Header, Query
from typing import Optional, List
from datetime import datetime
import jwt
import os

from ..services.supabase_client import get_supabase
from ..services.memory_extractor import extract_memories_from_transcript
from ..services.embeddings import generate_embedding
from ..models.memory import (
    Memory,
    MemoryCategory,
    MemoryVisibility,
    CreateMemoryRequest,
    UpdateMemoryRequest,
    ReviewMemoryRequest,
    ExtractMemoriesRequest,
    ExtractMemoriesResponse,
    MemoryListResponse,
    SearchMemoriesRequest,
)


router = APIRouter(prefix="/v1/memories", tags=["memories"])


def get_user_from_token(authorization: str = Header(...)) -> dict:
    """Extract user info from JWT token."""
    try:
        if not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Invalid authorization header")

        token = authorization.replace("Bearer ", "")
        jwt_secret = os.getenv("SUPABASE_JWT_SECRET")

        if not jwt_secret:
            raise HTTPException(status_code=500, detail="JWT secret not configured")

        payload = jwt.decode(token, jwt_secret, algorithms=["HS256"], audience="authenticated")

        return {
            "auth_id": payload.get("sub"),
            "email": payload.get("email"),
        }
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")


async def get_maity_user_id(auth_id: str) -> Optional[str]:
    """Get maity.users.id from auth.users.id"""
    supabase = get_supabase()

    result = (
        supabase.schema("maity")
        .table("users")
        .select("id")
        .eq("auth_id", auth_id)
        .single()
        .execute()
    )

    return result.data.get("id") if result.data else None


def _format_memory(data: dict) -> Memory:
    """Convert Supabase row to Memory model"""
    return Memory(
        id=data.get("id"),
        user_id=data.get("user_id"),
        auth_id=data.get("auth_id"),
        conversation_id=data.get("conversation_id"),
        content=data.get("content", ""),
        category=MemoryCategory(data.get("category", "interesting")),
        reviewed=data.get("reviewed", False),
        user_review=data.get("user_review"),
        manually_added=data.get("manually_added", False),
        edited=data.get("edited", False),
        deleted=data.get("deleted", False),
        visibility=MemoryVisibility(data.get("visibility", "private")),
        is_locked=data.get("is_locked", False),
        created_at=datetime.fromisoformat(data["created_at"].replace("Z", "+00:00")) if data.get("created_at") else None,
        updated_at=datetime.fromisoformat(data["updated_at"].replace("Z", "+00:00")) if data.get("updated_at") else None,
    )


@router.get("", response_model=MemoryListResponse)
async def list_memories(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    category: Optional[str] = Query(None, description="Filter by category: interesting, system, manual"),
    include_deleted: bool = Query(False),
    reviewed_only: bool = Query(False),
    pending_only: bool = Query(False),
    user_info: dict = Depends(get_user_from_token),
):
    """
    List user's memories.

    Filters:
    - category: Filter by memory category
    - include_deleted: Include soft-deleted memories
    - reviewed_only: Only show reviewed memories
    - pending_only: Only show memories pending review
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        # Build query
        query = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("*")
            .eq("user_id", user_id)
        )

        if not include_deleted:
            query = query.eq("deleted", False)

        if category:
            query = query.eq("category", category)

        if reviewed_only:
            query = query.eq("reviewed", True)

        if pending_only:
            query = query.eq("reviewed", False)

        result = (
            query
            .order("created_at", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )

        memories = [_format_memory(m) for m in (result.data or [])]

        # Get pending count
        pending_result = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("id", count="exact")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("reviewed", False)
            .execute()
        )
        pending_count = pending_result.count if pending_result.count else 0

        return MemoryListResponse(
            memories=memories,
            total=len(memories),
            pending_review=pending_count,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error listing memories: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to list memories: {e}")


@router.get("/{memory_id}", response_model=Memory)
async def get_memory(
    memory_id: str,
    user_info: dict = Depends(get_user_from_token),
):
    """Get a specific memory by ID."""
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        result = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("*")
            .eq("id", memory_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not result.data:
            raise HTTPException(status_code=404, detail="Memory not found")

        return _format_memory(result.data)

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error getting memory: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get memory: {e}")


@router.post("", response_model=Memory)
async def create_memory(
    request: CreateMemoryRequest,
    user_info: dict = Depends(get_user_from_token),
):
    """
    Create a new memory manually.

    Manually created memories are marked with category='manual' and manually_added=true.
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        # Generate embedding for the memory content
        embedding = await generate_embedding(request.content)

        data = {
            "user_id": user_id,
            "auth_id": auth_id,
            "content": request.content,
            "category": MemoryCategory.MANUAL.value,
            "conversation_id": request.conversation_id,
            "visibility": request.visibility.value,
            "manually_added": True,
            "reviewed": True,  # Manual memories are auto-reviewed
            "user_review": True,  # User created = approved
        }

        if embedding:
            data["embedding"] = embedding

        result = (
            supabase.schema("maity")
            .table("omi_memories")
            .insert(data)
            .execute()
        )

        if not result.data or len(result.data) == 0:
            raise HTTPException(status_code=500, detail="Failed to create memory")

        return _format_memory(result.data[0])

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error creating memory: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to create memory: {e}")


@router.patch("/{memory_id}", response_model=Memory)
async def update_memory(
    memory_id: str,
    request: UpdateMemoryRequest,
    user_info: dict = Depends(get_user_from_token),
):
    """Update a memory's content or visibility."""
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        # Verify memory exists and belongs to user
        existing = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("*")
            .eq("id", memory_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not existing.data:
            raise HTTPException(status_code=404, detail="Memory not found")

        if existing.data.get("is_locked"):
            raise HTTPException(status_code=403, detail="Memory is locked and cannot be edited")

        # Build update data
        update_data = {"edited": True}

        if request.content is not None:
            update_data["content"] = request.content
            # Regenerate embedding for updated content
            embedding = await generate_embedding(request.content)
            if embedding:
                update_data["embedding"] = embedding

        if request.visibility is not None:
            update_data["visibility"] = request.visibility.value

        result = (
            supabase.schema("maity")
            .table("omi_memories")
            .update(update_data)
            .eq("id", memory_id)
            .eq("user_id", user_id)
            .execute()
        )

        if not result.data or len(result.data) == 0:
            raise HTTPException(status_code=500, detail="Failed to update memory")

        return _format_memory(result.data[0])

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error updating memory: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to update memory: {e}")


@router.post("/{memory_id}/review", response_model=Memory)
async def review_memory(
    memory_id: str,
    request: ReviewMemoryRequest,
    user_info: dict = Depends(get_user_from_token),
):
    """
    Review a memory (approve or reject).

    - Approved: reviewed=true, user_review=true
    - Rejected: deleted=true, user_review=false
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        # Verify memory exists and belongs to user
        existing = (
            supabase.schema("maity")
            .table("omi_memories")
            .select("id")
            .eq("id", memory_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not existing.data:
            raise HTTPException(status_code=404, detail="Memory not found")

        # Update based on review decision
        update_data = {
            "reviewed": True,
            "user_review": request.approved,
        }

        if not request.approved:
            update_data["deleted"] = True

        result = (
            supabase.schema("maity")
            .table("omi_memories")
            .update(update_data)
            .eq("id", memory_id)
            .eq("user_id", user_id)
            .execute()
        )

        if not result.data or len(result.data) == 0:
            raise HTTPException(status_code=500, detail="Failed to review memory")

        return _format_memory(result.data[0])

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error reviewing memory: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to review memory: {e}")


@router.delete("/{memory_id}")
async def delete_memory(
    memory_id: str,
    hard_delete: bool = Query(False, description="Permanently delete instead of soft delete"),
    user_info: dict = Depends(get_user_from_token),
):
    """
    Delete a memory.

    - Soft delete (default): Sets deleted=true
    - Hard delete: Permanently removes from database
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        if hard_delete:
            result = (
                supabase.schema("maity")
                .table("omi_memories")
                .delete()
                .eq("id", memory_id)
                .eq("user_id", user_id)
                .execute()
            )
        else:
            result = (
                supabase.schema("maity")
                .table("omi_memories")
                .update({"deleted": True})
                .eq("id", memory_id)
                .eq("user_id", user_id)
                .execute()
            )

        return {"success": True, "deleted": memory_id}

    except Exception as e:
        print(f"[Memories] Error deleting memory: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete memory: {e}")


@router.post("/extract", response_model=ExtractMemoriesResponse)
async def extract_memories(
    request: ExtractMemoriesRequest,
    user_info: dict = Depends(get_user_from_token),
):
    """
    Extract memories from an existing conversation.

    Uses AI to analyze the conversation transcript and extract interesting facts/insights.
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        supabase = get_supabase()

        # Get conversation with transcript
        conv_result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, transcript_text")
            .eq("id", request.conversation_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not conv_result.data:
            raise HTTPException(status_code=404, detail="Conversation not found")

        transcript = conv_result.data.get("transcript_text", "")
        if not transcript:
            raise HTTPException(status_code=400, detail="Conversation has no transcript")

        # Extract memories using AI
        extracted = await extract_memories_from_transcript(
            transcript=transcript,
            conversation_id=request.conversation_id,
        )

        if not extracted:
            return ExtractMemoriesResponse(
                conversation_id=request.conversation_id,
                memories_created=0,
                memories=[],
            )

        # Insert memories with embeddings
        created_memories = []
        for mem_data in extracted:
            # Generate embedding for memory content
            embedding = await generate_embedding(mem_data["content"])

            insert_data = {
                "user_id": user_id,
                "auth_id": auth_id,
                "content": mem_data["content"],
                "category": mem_data.get("category", MemoryCategory.INTERESTING.value),
                "conversation_id": request.conversation_id,
                "manually_added": False,
                "reviewed": False,
            }

            if embedding:
                insert_data["embedding"] = embedding

            result = (
                supabase.schema("maity")
                .table("omi_memories")
                .insert(insert_data)
                .execute()
            )

            if result.data and len(result.data) > 0:
                created_memories.append(_format_memory(result.data[0]))

        return ExtractMemoriesResponse(
            conversation_id=request.conversation_id,
            memories_created=len(created_memories),
            memories=created_memories,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error extracting memories: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to extract memories: {e}")


@router.post("/search")
async def search_memories(
    request: SearchMemoriesRequest,
    user_info: dict = Depends(get_user_from_token),
):
    """
    Search memories using semantic similarity.

    Uses vector embeddings for semantic search across memory content.
    """
    auth_id = user_info.get("auth_id")
    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found")

    try:
        # Generate embedding for search query
        query_embedding = await generate_embedding(request.query)
        if not query_embedding:
            raise HTTPException(status_code=400, detail="Failed to generate search embedding")

        supabase = get_supabase()

        # Use RPC function for vector search
        params = {
            "p_user_id": user_id,
            "p_query_embedding": query_embedding,
            "p_limit": request.limit,
            "p_threshold": 0.7,
            "p_include_deleted": request.include_deleted,
        }

        if request.category:
            params["p_category"] = request.category.value

        result = supabase.schema("maity").rpc(
            "search_omi_memories",
            params
        ).execute()

        memories = []
        for row in (result.data or []):
            memories.append({
                "id": row.get("id"),
                "content": row.get("content"),
                "category": row.get("category"),
                "conversation_id": row.get("conversation_id"),
                "reviewed": row.get("reviewed"),
                "visibility": row.get("visibility"),
                "created_at": row.get("created_at"),
                "similarity": row.get("similarity"),
            })

        return {
            "query": request.query,
            "memories": memories,
            "total": len(memories),
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Memories] Error searching memories: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to search memories: {e}")
