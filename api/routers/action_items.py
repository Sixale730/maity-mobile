"""Action items router - CRUD for tasks extracted from conversations"""
from datetime import datetime
from typing import List, Optional
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Query, Path
from pydantic import BaseModel

from ..services.firebase_client import get_db


router = APIRouter(prefix="/v1/action-items", tags=["action_items"])


class ActionItemCreate(BaseModel):
    """Create action item request"""
    description: str
    due_at: Optional[datetime] = None
    conversation_id: Optional[str] = None


class ActionItemUpdate(BaseModel):
    """Update action item request"""
    description: Optional[str] = None
    completed: Optional[bool] = None
    due_at: Optional[datetime] = None


class ActionItemResponse(BaseModel):
    """Action item response"""
    id: str
    description: str
    completed: bool
    due_at: Optional[datetime]
    conversation_id: Optional[str]
    created_at: datetime


@router.get("/", response_model=List[ActionItemResponse])
async def list_action_items(
    user_id: str = Query(..., description="Firebase user ID"),
    completed: Optional[bool] = Query(None, description="Filter by completion status"),
    limit: int = Query(50, ge=1, le=100),
):
    """List user's action items"""
    try:
        db = get_db()
        query = db.collection("users").document(user_id).collection("action_items")

        if completed is not None:
            query = query.where("completed", "==", completed)

        docs = query.order_by("created_at", direction="DESCENDING").limit(limit).stream()

        items = []
        for doc in docs:
            data = doc.to_dict()
            items.append(ActionItemResponse(
                id=doc.id,
                description=data.get("description", ""),
                completed=data.get("completed", False),
                due_at=data.get("due_at"),
                conversation_id=data.get("conversation_id"),
                created_at=data.get("created_at", datetime.now()),
            ))

        return items
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch action items: {e}")


@router.post("/", response_model=ActionItemResponse)
async def create_action_item(
    user_id: str = Query(..., description="Firebase user ID"),
    item: ActionItemCreate = ...,
):
    """Create a new action item"""
    try:
        db = get_db()
        item_id = str(uuid4())
        now = datetime.now()

        data = {
            "description": item.description,
            "completed": False,
            "due_at": item.due_at,
            "conversation_id": item.conversation_id,
            "created_at": now,
        }

        db.collection("users").document(user_id)\
          .collection("action_items").document(item_id).set(data)

        return ActionItemResponse(
            id=item_id,
            **data,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create action item: {e}")


@router.patch("/{item_id}", response_model=ActionItemResponse)
async def update_action_item(
    item_id: str = Path(..., description="Action item ID"),
    user_id: str = Query(..., description="Firebase user ID"),
    update: ActionItemUpdate = ...,
):
    """Update an action item"""
    try:
        db = get_db()
        doc_ref = db.collection("users").document(user_id)\
                    .collection("action_items").document(item_id)

        doc = doc_ref.get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="Action item not found")

        # Build update dict
        update_data = {}
        if update.description is not None:
            update_data["description"] = update.description
        if update.completed is not None:
            update_data["completed"] = update.completed
        if update.due_at is not None:
            update_data["due_at"] = update.due_at

        if update_data:
            doc_ref.update(update_data)

        # Get updated document
        updated_doc = doc_ref.get()
        data = updated_doc.to_dict()

        return ActionItemResponse(
            id=item_id,
            description=data.get("description", ""),
            completed=data.get("completed", False),
            due_at=data.get("due_at"),
            conversation_id=data.get("conversation_id"),
            created_at=data.get("created_at", datetime.now()),
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to update action item: {e}")


@router.delete("/{item_id}")
async def delete_action_item(
    item_id: str = Path(..., description="Action item ID"),
    user_id: str = Query(..., description="Firebase user ID"),
):
    """Delete an action item"""
    try:
        db = get_db()
        doc_ref = db.collection("users").document(user_id)\
                    .collection("action_items").document(item_id)

        doc = doc_ref.get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="Action item not found")

        doc_ref.delete()

        return {"success": True, "message": "Action item deleted"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete action item: {e}")
