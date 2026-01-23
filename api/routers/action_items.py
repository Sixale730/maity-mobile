"""Action items router - Extract action items from conversations stored in Supabase"""
from datetime import datetime, timedelta
from typing import List, Optional
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Query, Path
from pydantic import BaseModel

from ..services.supabase_client import get_supabase


router = APIRouter(prefix="/v1/action-items", tags=["action_items"])


class ActionItemResponse(BaseModel):
    """Action item response with full metadata"""
    id: str
    description: str
    completed: bool
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    conversation_id: Optional[str] = None
    is_locked: bool = False
    exported: bool = False
    export_date: Optional[datetime] = None
    export_platform: Optional[str] = None


class ActionItemsListResponse(BaseModel):
    """Response for list of action items"""
    action_items: List[ActionItemResponse]
    has_more: bool
    total: int


class ActionItemUpdate(BaseModel):
    """Update action item request"""
    description: Optional[str] = None
    completed: Optional[bool] = None
    due_at: Optional[datetime] = None


@router.get("/from-conversations", response_model=ActionItemsListResponse)
async def get_action_items_from_conversations(
    user_id: str = Query(..., description="User ID (maity.users.id)"),
    completed: Optional[bool] = Query(None, description="Filter by completion status"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    """
    Extract action items from all user conversations stored in Supabase.

    Action items are stored in the structured.action_items field of omi_conversations.
    This endpoint flattens all action items across conversations with their metadata.
    """
    supabase = get_supabase()

    try:
        # Query all conversations with action_items
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, emoji, action_items, created_at")
            .eq("user_id", user_id)
            .eq("deleted", False)
            .eq("discarded", False)
            .order("created_at", desc=True)
            .execute()
        )

        conversations = result.data if result.data else []

        # Extract and flatten all action items with context
        all_items: List[ActionItemResponse] = []
        item_index = 0

        for conv in conversations:
            conv_id = conv.get("id")
            conv_created_at = conv.get("created_at")
            action_items_raw = conv.get("action_items") or []

            for idx, item in enumerate(action_items_raw):
                item_completed = item.get("completed", False)

                # Filter by completed status if specified
                if completed is not None and item_completed != completed:
                    continue

                # Generate unique ID: conversation_id + index
                item_id = f"{conv_id}_{idx}"

                all_items.append(ActionItemResponse(
                    id=item_id,
                    description=item.get("description", ""),
                    completed=item_completed,
                    created_at=datetime.fromisoformat(conv_created_at.replace("Z", "+00:00")) if conv_created_at else None,
                    conversation_id=conv_id,
                    is_locked=False,
                    exported=False,
                ))
                item_index += 1

        # Apply pagination
        total = len(all_items)
        paginated_items = all_items[offset:offset + limit]
        has_more = (offset + limit) < total

        return ActionItemsListResponse(
            action_items=paginated_items,
            has_more=has_more,
            total=total,
        )

    except Exception as e:
        print(f"[Action Items] Error fetching action items: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to fetch action items: {e}")


@router.patch("/{item_id}", response_model=ActionItemResponse)
async def update_action_item(
    item_id: str = Path(..., description="Action item ID (format: conversation_id_index)"),
    user_id: str = Query(..., description="User ID (maity.users.id)"),
    update: ActionItemUpdate = ...,
):
    """
    Update an action item in a conversation.

    The item_id format is: conversation_id_index (e.g., "abc-123_0")
    """
    supabase = get_supabase()

    try:
        # Parse item_id to get conversation_id and index
        parts = item_id.rsplit("_", 1)
        if len(parts) != 2:
            raise HTTPException(status_code=400, detail="Invalid action item ID format")

        conversation_id, idx_str = parts
        try:
            item_idx = int(idx_str)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid action item index")

        # Get the conversation
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, action_items, created_at")
            .eq("id", conversation_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not result.data:
            raise HTTPException(status_code=404, detail="Conversation not found")

        conv = result.data
        action_items = conv.get("action_items") or []

        if item_idx < 0 or item_idx >= len(action_items):
            raise HTTPException(status_code=404, detail="Action item not found")

        # Update the action item
        if update.description is not None:
            action_items[item_idx]["description"] = update.description
        if update.completed is not None:
            action_items[item_idx]["completed"] = update.completed

        # Save back to database
        supabase.schema("maity").table("omi_conversations").update({
            "action_items": action_items
        }).eq("id", conversation_id).eq("user_id", user_id).execute()

        # Return updated item
        updated_item = action_items[item_idx]
        conv_created_at = conv.get("created_at")

        return ActionItemResponse(
            id=item_id,
            description=updated_item.get("description", ""),
            completed=updated_item.get("completed", False),
            created_at=datetime.fromisoformat(conv_created_at.replace("Z", "+00:00")) if conv_created_at else None,
            conversation_id=conversation_id,
            is_locked=False,
            exported=False,
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Action Items] Error updating action item: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to update action item: {e}")


@router.delete("/{item_id}")
async def delete_action_item(
    item_id: str = Path(..., description="Action item ID (format: conversation_id_index)"),
    user_id: str = Query(..., description="User ID (maity.users.id)"),
):
    """
    Delete an action item from a conversation.

    The item_id format is: conversation_id_index (e.g., "abc-123_0")
    """
    supabase = get_supabase()

    try:
        # Parse item_id to get conversation_id and index
        parts = item_id.rsplit("_", 1)
        if len(parts) != 2:
            raise HTTPException(status_code=400, detail="Invalid action item ID format")

        conversation_id, idx_str = parts
        try:
            item_idx = int(idx_str)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid action item index")

        # Get the conversation
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, action_items")
            .eq("id", conversation_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not result.data:
            raise HTTPException(status_code=404, detail="Conversation not found")

        conv = result.data
        action_items = conv.get("action_items") or []

        if item_idx < 0 or item_idx >= len(action_items):
            raise HTTPException(status_code=404, detail="Action item not found")

        # Remove the action item
        action_items.pop(item_idx)

        # Save back to database
        supabase.schema("maity").table("omi_conversations").update({
            "action_items": action_items
        }).eq("id", conversation_id).eq("user_id", user_id).execute()

        return {"success": True, "message": "Action item deleted"}

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Action Items] Error deleting action item: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete action item: {e}")
