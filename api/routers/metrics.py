"""Metrics router - User usage metrics"""
from fastapi import APIRouter, HTTPException, Query, Path
from typing import Literal

from ..models.metrics import UserMetricsResponse
from ..services.firebase_client import get_user_metrics


router = APIRouter(prefix="/v1/users", tags=["metrics"])


@router.get("/{user_id}/metrics", response_model=UserMetricsResponse)
async def get_metrics(
    user_id: str = Path(..., description="Firebase user ID"),
    period: Literal["today", "weekly", "monthly", "yearly", "all"] = Query(
        "monthly",
        description="Time period for metrics aggregation"
    ),
):
    """
    Get usage metrics for a user.

    Aggregates:
    - Total transcription seconds
    - Total words transcribed
    - Number of conversations
    - Insights gained (action items + events)
    - Top categories breakdown
    - Daily history

    Periods:
    - today: Last 24 hours
    - weekly: Last 7 days
    - monthly: Last 30 days
    - yearly: Last 365 days
    - all: All time
    """
    try:
        metrics = await get_user_metrics(user_id, period)
        return metrics
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch metrics: {e}")


@router.get("/{user_id}/metrics/summary")
async def get_metrics_summary(
    user_id: str = Path(..., description="Firebase user ID"),
):
    """
    Get a quick summary of user metrics across all periods.

    Useful for dashboard display.
    """
    try:
        today = await get_user_metrics(user_id, "today")
        monthly = await get_user_metrics(user_id, "monthly")
        all_time = await get_user_metrics(user_id, "all")

        return {
            "user_id": user_id,
            "today": {
                "conversations": today.stats.conversations_count,
                "minutes": round(today.stats.transcription_seconds / 60, 1),
                "words": today.stats.words_transcribed,
            },
            "monthly": {
                "conversations": monthly.stats.conversations_count,
                "minutes": round(monthly.stats.transcription_seconds / 60, 1),
                "words": monthly.stats.words_transcribed,
                "insights": monthly.stats.insights_gained,
            },
            "all_time": {
                "conversations": all_time.stats.conversations_count,
                "minutes": round(all_time.stats.transcription_seconds / 60, 1),
                "words": all_time.stats.words_transcribed,
                "insights": all_time.stats.insights_gained,
                "top_categories": [
                    {"category": c.category, "count": c.count}
                    for c in all_time.stats.top_categories[:5]
                ],
            },
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch metrics summary: {e}")
