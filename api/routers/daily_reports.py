"""Daily communication reports router - Cron job and query endpoints"""
from datetime import datetime, timezone
from fastapi import APIRouter, HTTPException, Depends, Header, Query
from typing import Optional, List
import os

from .feedback import get_user_from_token, get_maity_user_id, is_developer_email
from ..services.daily_report_generator import generate_daily_reports, generate_daily_report_for_user
from ..services.supabase_client import get_supabase


router = APIRouter(prefix="/v1/daily-reports", tags=["daily-reports"])


def _verify_cron_secret(authorization: str = Header(...)):
    """Verify the cron job secret for the generate endpoint."""
    cron_secret = os.getenv("CRON_SECRET")
    if not cron_secret:
        raise HTTPException(status_code=500, detail="CRON_SECRET not configured")

    token = authorization.replace("Bearer ", "") if authorization.startswith("Bearer ") else authorization
    if token != cron_secret:
        raise HTTPException(status_code=401, detail="Invalid cron secret")


@router.get("/generate")
async def generate_reports(
    date: Optional[str] = Query(None, description="Target date YYYY-MM-DD, defaults to today Mexico time"),
    authorization: str = Header(...),
):
    """Generate daily communication reports for all users.

    Called by Vercel cron at 00:00 UTC (6 PM Mexico CST).
    Requires CRON_SECRET in Authorization header.
    """
    _verify_cron_secret(authorization)

    print(f"[DailyReport] Cron triggered at {datetime.now(timezone.utc).isoformat()}, date={date}")

    try:
        result = await generate_daily_reports(target_date=date)
        print(f"[DailyReport] Cron result: {result}")
        return result
    except Exception as e:
        print(f"[DailyReport] Cron FAILED: {e}")
        return {"users_processed": 0, "reports_generated": 0, "errors": [str(e)]}


@router.post("/trigger")
async def trigger_report_for_user(
    date: str = Query(..., description="Target date YYYY-MM-DD"),
    user: dict = Depends(get_user_from_token),
):
    """Manually trigger daily report generation for the current user.

    Restricted to developer emails (@asertio.mx).
    """
    email = user.get("email")
    if not is_developer_email(email):
        raise HTTPException(status_code=403, detail="Access denied. Developer only.")

    maity_user_id = await get_maity_user_id(user["auth_id"])
    if not maity_user_id:
        raise HTTPException(status_code=404, detail="User not found in maity.users")

    result = await generate_daily_report_for_user(user_id=maity_user_id, target_date=date)
    return result


@router.get("/latest")
async def get_latest_report(
    user_id: str = Query(..., description="Maity user ID"),
    user: dict = Depends(get_user_from_token),
):
    """Get the latest daily report for a user."""
    # Verify user owns this data
    auth_user_id = await get_maity_user_id(user["auth_id"])
    if auth_user_id != user_id:
        raise HTTPException(status_code=403, detail="Access denied")

    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("daily_communication_reports")
            .select("*")
            .eq("user_id", user_id)
            .order("report_date", desc=True)
            .limit(1)
            .execute()
        )

        if not result.data:
            return {"report": None}

        return {"report": _format_report(result.data[0])}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error fetching report: {e}")


@router.get("/by-date")
async def get_report_by_date(
    user_id: str = Query(..., description="Maity user ID"),
    date: str = Query(..., description="Report date YYYY-MM-DD"),
    user: dict = Depends(get_user_from_token),
):
    """Get a daily report for a specific date."""
    auth_user_id = await get_maity_user_id(user["auth_id"])
    if auth_user_id != user_id:
        raise HTTPException(status_code=403, detail="Access denied")

    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("daily_communication_reports")
            .select("*")
            .eq("user_id", user_id)
            .eq("report_date", date)
            .limit(1)
            .execute()
        )

        if not result.data:
            return {"report": None}

        return {"report": _format_report(result.data[0])}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error fetching report: {e}")


@router.get("/history")
async def get_report_history(
    user_id: str = Query(..., description="Maity user ID"),
    limit: int = Query(7, description="Number of reports to return", ge=1, le=30),
    user: dict = Depends(get_user_from_token),
):
    """Get recent daily report history."""
    auth_user_id = await get_maity_user_id(user["auth_id"])
    if auth_user_id != user_id:
        raise HTTPException(status_code=403, detail="Access denied")

    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("daily_communication_reports")
            .select("*")
            .eq("user_id", user_id)
            .order("report_date", desc=True)
            .limit(limit)
            .execute()
        )

        reports = [_format_report(r) for r in (result.data or [])]
        return {"reports": reports, "total": len(reports)}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error fetching history: {e}")


def _format_report(row: dict) -> dict:
    """Format a database row into the API response format."""
    return {
        "id": row.get("id"),
        "user_id": row.get("user_id"),
        "report_date": row.get("report_date"),
        "conversations_analyzed": row.get("conversations_analyzed", 0),
        "total_words_analyzed": row.get("total_words_analyzed", 0),
        "total_duration_seconds": row.get("total_duration_seconds", 0),
        "total_filler_words": row.get("total_filler_words", {}),
        "total_filler_count": row.get("total_filler_count", 0),
        "total_pero_count": row.get("total_pero_count", 0),
        "total_objection_words": row.get("total_objection_words", {}),
        "objections_received": row.get("objections_received", []),
        "objections_made": row.get("objections_made", []),
        "scores": {
            "clarity": float(row.get("score_clarity", 0)),
            "structure": float(row.get("score_structure", 0)),
            "vocabulario": float(row.get("score_vocabulario", 0)),
            "empatia": float(row.get("score_empatia", 0)),
            "objetivo": float(row.get("score_objetivo", 0)),
            "adaptacion": float(row.get("score_adaptacion", 0)),
            "calls_to_action": float(row.get("score_calls_to_action", 0)),
            "objection_handling": float(row.get("score_objection_handling", 0)),
            "overall": float(row.get("score_overall", 0)),
        },
        "top_strengths": row.get("top_strengths", []),
        "top_areas_to_improve": row.get("top_areas_to_improve", []),
        "daily_summary": row.get("daily_summary", ""),
        "recommendations": row.get("recommendations", []),
        "trend": {
            "trend": row.get("trend", "first_report"),
            "previous_overall": (row.get("trend_details") or {}).get("previous_overall"),
            "change": (row.get("trend_details") or {}).get("change"),
        },
        "conversation_ids": row.get("conversation_ids", []),
        "created_at": row.get("created_at"),
    }
