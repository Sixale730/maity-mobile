"""Metrics router - User usage metrics"""
from fastapi import APIRouter, HTTPException, Query, Path
from typing import Literal

from ..models.metrics import UserMetricsResponse, UserStats, CategoryCount, DailyMetrics
from ..services.supabase_client import get_user_metrics as get_supabase_user_metrics


router = APIRouter(prefix="/v1/users", tags=["metrics"])


@router.get("/{user_id}/metrics", response_model=UserMetricsResponse)
async def get_metrics(
    user_id: str = Path(..., description="Maity user ID (UUID from maity.users)"),
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
        metrics_dict = await get_supabase_user_metrics(user_id, period)

        # Convert dict to Pydantic models
        stats_dict = metrics_dict.get("stats", {})
        stats = UserStats(
            transcription_seconds=stats_dict.get("transcription_seconds", 0),
            words_transcribed=stats_dict.get("words_transcribed", 0),
            conversations_count=stats_dict.get("conversations_count", 0),
            insights_gained=stats_dict.get("insights_gained", 0),
            memories_count=stats_dict.get("memories_count", 0),
            top_categories=[
                CategoryCount(category=c["category"], count=c["count"])
                for c in stats_dict.get("top_categories", [])
            ],
        )

        history = [
            DailyMetrics(
                date=h["date"],
                conversations=h["conversations"],
                minutes=h["minutes"],
                words=h["words"],
                insights=h.get("insights", 0),
                memories=h.get("memories", 0),
            )
            for h in metrics_dict.get("history", [])
        ]

        return UserMetricsResponse(
            period=metrics_dict.get("period", period),
            user_id=metrics_dict.get("user_id", user_id),
            stats=stats,
            history=history,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch metrics: {e}")


@router.get("/{user_id}/metrics/summary")
async def get_metrics_summary(
    user_id: str = Path(..., description="Maity user ID (UUID from maity.users)"),
):
    """
    Get a quick summary of user metrics across all periods.

    Useful for dashboard display.
    """
    try:
        today = await get_supabase_user_metrics(user_id, "today")
        monthly = await get_supabase_user_metrics(user_id, "monthly")
        all_time = await get_supabase_user_metrics(user_id, "all")

        today_stats = today.get("stats", {})
        monthly_stats = monthly.get("stats", {})
        all_time_stats = all_time.get("stats", {})

        return {
            "user_id": user_id,
            "today": {
                "conversations": today_stats.get("conversations_count", 0),
                "minutes": round(today_stats.get("transcription_seconds", 0) / 60, 1),
                "words": today_stats.get("words_transcribed", 0),
            },
            "monthly": {
                "conversations": monthly_stats.get("conversations_count", 0),
                "minutes": round(monthly_stats.get("transcription_seconds", 0) / 60, 1),
                "words": monthly_stats.get("words_transcribed", 0),
                "insights": monthly_stats.get("insights_gained", 0),
            },
            "all_time": {
                "conversations": all_time_stats.get("conversations_count", 0),
                "minutes": round(all_time_stats.get("transcription_seconds", 0) / 60, 1),
                "words": all_time_stats.get("words_transcribed", 0),
                "insights": all_time_stats.get("insights_gained", 0),
                "top_categories": all_time_stats.get("top_categories", [])[:5],
            },
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch metrics summary: {e}")
