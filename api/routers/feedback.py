"""Feedback router - User feedback submission and listing"""
from fastapi import APIRouter, HTTPException, Depends, Header, Query
from pydantic import BaseModel
from typing import Optional, List, Literal
from datetime import datetime

from ..services.supabase_client import get_supabase
from ..services.supabase_auth import get_user_from_token


router = APIRouter(prefix="/v1/feedback", tags=["feedback"])


# Pydantic models
class FeedbackSubmit(BaseModel):
    feedback_type: Literal["comment", "bug", "suggestion"]
    message: str
    app_version: Optional[str] = None
    device_info: Optional[str] = None


class FeedbackResponse(BaseModel):
    id: str
    feedback_type: str
    message: str
    app_version: Optional[str]
    device_info: Optional[str]
    status: str
    created_at: str


class FeedbackListResponse(BaseModel):
    feedback: List[FeedbackResponse]
    total: int


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


def is_developer_email(email: str) -> bool:
    """Check if email is a developer email (@asertio.mx)"""
    return email and email.endswith("@asertio.mx")


@router.post("/submit", response_model=FeedbackResponse)
async def submit_feedback(
    feedback: FeedbackSubmit,
    user_info: dict = Depends(get_user_from_token),
):
    """
    Submit user feedback.

    Types:
    - comment: General comment or opinion
    - bug: Bug report
    - suggestion: Feature suggestion
    """
    auth_id = user_info.get("auth_id")

    if not auth_id:
        raise HTTPException(status_code=401, detail="User not authenticated")

    # Get maity user id
    user_id = await get_maity_user_id(auth_id)
    if not user_id:
        raise HTTPException(status_code=404, detail="User not found in maity.users")

    try:
        supabase = get_supabase()

        data = {
            "user_id": user_id,
            "auth_id": auth_id,
            "feedback_type": feedback.feedback_type,
            "message": feedback.message,
            "app_version": feedback.app_version,
            "device_info": feedback.device_info,
            "status": "pending",
        }

        result = (
            supabase.schema("maity")
            .table("user_feedback")
            .insert(data)
            .execute()
        )

        if not result.data or len(result.data) == 0:
            raise HTTPException(status_code=500, detail="Failed to insert feedback")

        inserted = result.data[0]

        return FeedbackResponse(
            id=inserted["id"],
            feedback_type=inserted["feedback_type"],
            message=inserted["message"],
            app_version=inserted.get("app_version"),
            device_info=inserted.get("device_info"),
            status=inserted["status"],
            created_at=inserted["created_at"],
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to submit feedback: {e}")


@router.get("/list", response_model=FeedbackListResponse)
async def list_feedback(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    status: Optional[str] = Query(None, description="Filter by status: pending, reviewed, resolved"),
    user_info: dict = Depends(get_user_from_token),
):
    """
    List all feedback submissions.

    Only accessible by developers (@asertio.mx emails).
    """
    email = user_info.get("email")

    if not is_developer_email(email):
        raise HTTPException(
            status_code=403,
            detail="Access denied. Only developers can view all feedback."
        )

    try:
        supabase = get_supabase()

        # Build query - join with users to get email
        query = (
            supabase.schema("maity")
            .table("user_feedback")
            .select("*, users!user_feedback_user_id_fkey(email)")
        )

        if status:
            query = query.eq("status", status)

        result = (
            query
            .order("created_at", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )

        feedback_list = []
        for item in (result.data or []):
            user_email = ""
            if item.get("users"):
                user_email = item["users"].get("email", "")

            feedback_list.append(FeedbackResponse(
                id=item["id"],
                feedback_type=item["feedback_type"],
                message=item["message"],
                app_version=item.get("app_version"),
                device_info=f"{item.get('device_info', '')} | {user_email}".strip(" | "),
                status=item["status"],
                created_at=item["created_at"],
            ))

        # Get total count
        count_result = (
            supabase.schema("maity")
            .table("user_feedback")
            .select("id", count="exact")
            .execute()
        )
        total = count_result.count if count_result.count else len(feedback_list)

        return FeedbackListResponse(
            feedback=feedback_list,
            total=total,
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list feedback: {e}")


@router.get("/my", response_model=FeedbackListResponse)
async def get_my_feedback(
    limit: int = Query(20, ge=1, le=100),
    user_info: dict = Depends(get_user_from_token),
):
    """
    Get current user's own feedback submissions.
    """
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
            .table("user_feedback")
            .select("*")
            .eq("user_id", user_id)
            .order("created_at", desc=True)
            .limit(limit)
            .execute()
        )

        feedback_list = [
            FeedbackResponse(
                id=item["id"],
                feedback_type=item["feedback_type"],
                message=item["message"],
                app_version=item.get("app_version"),
                device_info=item.get("device_info"),
                status=item["status"],
                created_at=item["created_at"],
            )
            for item in (result.data or [])
        ]

        return FeedbackListResponse(
            feedback=feedback_list,
            total=len(feedback_list),
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get feedback: {e}")
