"""Communication feedback router - Get aggregated communication analysis"""
from datetime import datetime, timedelta
from typing import Optional, List
from pydantic import BaseModel

from fastapi import APIRouter, HTTPException, Query, Depends

from ..services.supabase_client import get_supabase
from ..services.supabase_auth import optional_auth_user_id
from ..services.communication_analyzer import aggregate_feedback
from ..models.communication import (
    CommunicationFeedback,
    CommunicationObservations,
    AggregatedFeedback,
    CommunicationFeedbackResponse,
)


router = APIRouter(prefix="/v1/communication", tags=["communication"])


# ============ Response Models ============


class FeedbackResponse(BaseModel):
    """Response with aggregated communication feedback"""
    user_id: str
    period: str
    feedback: AggregatedFeedback


# ============ Helper Functions ============


def _get_date_filter(period: str) -> Optional[datetime]:
    """Get start date filter based on period"""
    now = datetime.utcnow()

    if period == "today":
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif period == "weekly":
        return now - timedelta(days=7)
    elif period == "monthly":
        return now - timedelta(days=30)
    elif period == "yearly":
        return now - timedelta(days=365)
    elif period == "all":
        return None
    else:
        return now - timedelta(days=30)  # Default to monthly


async def _get_conversations_feedback(
    user_id: str,
    start_date: Optional[datetime] = None,
    limit: int = 100,
) -> List[dict]:
    """
    Get communication_feedback from conversations.

    Returns list of feedback dictionaries from conversations that have feedback.
    """
    supabase = get_supabase()

    query = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("id, communication_feedback, created_at")
        .eq("user_id", user_id)
        .eq("deleted", False)
        .not_.is_("communication_feedback", "null")
    )

    if start_date:
        query = query.gte("created_at", start_date.isoformat())

    result = (
        query
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
    )

    return result.data if result.data else []


def _aggregate_observations(feedbacks: List[CommunicationFeedback]) -> CommunicationObservations:
    """
    Create a summary of observations from multiple feedbacks.

    Takes the most recent non-empty observation for each category.
    """
    clarity = ""
    structure = ""
    calls_to_action = ""
    objections = ""

    for fb in feedbacks:
        if fb.observations.clarity and not clarity:
            clarity = fb.observations.clarity
        if fb.observations.structure and not structure:
            structure = fb.observations.structure
        if fb.observations.calls_to_action and not calls_to_action:
            calls_to_action = fb.observations.calls_to_action
        if fb.observations.objections and not objections:
            objections = fb.observations.objections

        # Stop if we have all observations
        if clarity and structure and calls_to_action and objections:
            break

    return CommunicationObservations(
        clarity=clarity or "No hay suficientes conversaciones para analizar la claridad.",
        structure=structure or "No hay suficientes conversaciones para analizar la estructura.",
        calls_to_action=calls_to_action or "No hay suficientes conversaciones para analizar los llamados a acción.",
        objections=objections or "No hay suficientes conversaciones para analizar el manejo de objeciones.",
    )


# ============ Endpoints ============


@router.get("/feedback", response_model=FeedbackResponse)
async def get_communication_feedback(
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    period: str = Query("monthly", description="Period: today, weekly, monthly, yearly, all"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Get aggregated communication feedback for a user over a time period.

    Returns:
    - top_strengths: Most common strengths across conversations
    - top_areas_to_improve: Most common areas to improve
    - observations_summary: Summary observations for each category
    - conversations_analyzed: Number of conversations with feedback
    """
    # Get date filter
    start_date = _get_date_filter(period)

    try:
        # Get conversations with feedback
        conversations = await _get_conversations_feedback(
            user_id=user_id,
            start_date=start_date,
        )

        if not conversations:
            # No feedback yet
            return FeedbackResponse(
                user_id=user_id,
                period=period,
                feedback=AggregatedFeedback(
                    top_strengths=[],
                    top_areas_to_improve=[],
                    observations_summary=CommunicationObservations(
                        clarity="Aún no hay feedback. Graba conversaciones para obtener insights.",
                        structure="Aún no hay feedback. Graba conversaciones para obtener insights.",
                        calls_to_action="Aún no hay feedback. Graba conversaciones para obtener insights.",
                        objections="Aún no hay feedback. Graba conversaciones para obtener insights.",
                    ),
                    conversations_analyzed=0,
                    period=period,
                ),
            )

        # Parse feedback from conversations
        feedback_list = []
        for conv in conversations:
            fb_data = conv.get("communication_feedback")
            if fb_data and isinstance(fb_data, dict):
                try:
                    obs_data = fb_data.get("observations", {})
                    fb = CommunicationFeedback(
                        strengths=fb_data.get("strengths", []),
                        areas_to_improve=fb_data.get("areas_to_improve", []),
                        observations=CommunicationObservations(
                            clarity=obs_data.get("clarity", ""),
                            structure=obs_data.get("structure", ""),
                            calls_to_action=obs_data.get("calls_to_action", ""),
                            objections=obs_data.get("objections", ""),
                        ),
                        summary=fb_data.get("summary", ""),
                    )
                    feedback_list.append(fb)
                except Exception as e:
                    print(f"[Communication Router] Failed to parse feedback: {e}")
                    continue

        # Aggregate feedback
        aggregated = aggregate_feedback(feedback_list)
        observations_summary = _aggregate_observations(feedback_list)

        return FeedbackResponse(
            user_id=user_id,
            period=period,
            feedback=AggregatedFeedback(
                top_strengths=aggregated["top_strengths"],
                top_areas_to_improve=aggregated["top_areas_to_improve"],
                observations_summary=observations_summary,
                conversations_analyzed=aggregated["conversations_analyzed"],
                period=period,
            ),
        )

    except Exception as e:
        print(f"[Communication Router] Failed to get feedback: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get communication feedback: {str(e)}",
        )


@router.get("/feedback/{conversation_id}")
async def get_conversation_feedback(
    conversation_id: str,
    user_id: str = Query(..., description="User ID (maity.users UUID)"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Get communication feedback for a specific conversation.
    """
    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("id, title, communication_feedback, created_at")
            .eq("id", conversation_id)
            .eq("user_id", user_id)
            .single()
            .execute()
        )

        if not result.data:
            raise HTTPException(status_code=404, detail="Conversation not found")

        return {
            "conversation_id": result.data.get("id"),
            "title": result.data.get("title"),
            "feedback": result.data.get("communication_feedback"),
            "created_at": result.data.get("created_at"),
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"[Communication Router] Failed to get conversation feedback: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get feedback: {str(e)}",
        )
