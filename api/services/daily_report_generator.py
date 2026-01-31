"""Daily communication report generator service.

Aggregates communication_feedback from conversations of the day,
calls OpenAI for evaluation scores, and upserts into daily_communication_reports.
"""
import asyncio
import json
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

import openai

from ..models.daily_report import DailyCommunicationReport, DailyScores, DailyTrend
from .supabase_client import get_supabase
from .utils import parse_json_from_llm

# Mexico City is UTC-6 (CST) / UTC-5 (CDT)
MEXICO_UTC_OFFSET = -6

DAILY_EVALUATION_PROMPT = """Eres un coach de comunicación profesional. Analiza las siguientes métricas agregadas de las conversaciones de hoy de un usuario y genera una evaluación diaria.

MÉTRICAS DEL DÍA:
- Conversaciones analizadas: {conversations_analyzed}
- Palabras totales: {total_words}
- Duración total: {total_duration_minutes} minutos
- Muletillas detectadas: {filler_words}
- Total muletillas: {total_filler_count}
- Conteo de "pero": {pero_count}
- Palabras de objeción: {objection_words}
- Objeciones recibidas: {objections_received}
- Objeciones hechas: {objections_made}
- Fortalezas detectadas (de análisis individuales): {strengths}
- Áreas de mejora detectadas: {areas_to_improve}

{trend_context}

Genera una evaluación con scores del 1 al 10 y feedback constructivo.

Responde ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{{
  "score_clarity": 7.5,
  "score_structure": 6.0,
  "score_calls_to_action": 5.5,
  "score_objection_handling": 8.0,
  "score_overall": 6.8,
  "top_strengths": ["fortaleza 1", "fortaleza 2", "fortaleza 3"],
  "top_areas_to_improve": ["área 1", "área 2", "área 3"],
  "daily_summary": "Resumen del desempeño comunicativo del día en 1-2 oraciones.",
  "recommendations": ["recomendación concreta 1", "recomendación concreta 2", "recomendación concreta 3"],
  "trend": "improving"
}}

REGLAS:
- Scores de 1.0 a 10.0 (un decimal)
- score_overall es el promedio ponderado (claridad 30%, estructura 25%, llamados a acción 25%, objeciones 20%)
- top_strengths: máximo 5, basadas en las fortalezas detectadas
- top_areas_to_improve: máximo 5, basadas en áreas de mejora detectadas
- recommendations: 2-4 acciones concretas y específicas para mejorar mañana
- daily_summary: máximo 200 caracteres
- trend: "improving" si mejora vs ayer, "stable" si similar, "declining" si baja, "first_report" si no hay reporte previo"""


async def generate_daily_reports(target_date: Optional[str] = None) -> dict:
    """Generate daily reports for all users who had conversations today.

    Args:
        target_date: Date string YYYY-MM-DD. Defaults to today in Mexico time.

    Returns:
        Summary dict with users_processed, reports_generated, errors
    """
    supabase = get_supabase()

    # Calculate target date in Mexico time
    if target_date:
        report_date = target_date
    else:
        now_utc = datetime.now(timezone.utc)
        mexico_time = now_utc + timedelta(hours=MEXICO_UTC_OFFSET)
        report_date = mexico_time.strftime("%Y-%m-%d")

    print(f"[DailyReport] Generating reports for date: {report_date}")

    # Find all users who have completed conversations today
    # with communication_feedback
    date_start = f"{report_date}T00:00:00"
    date_end = f"{report_date}T23:59:59"

    try:
        result = (
            supabase.schema("maity")
            .table("omi_conversations")
            .select("user_id")
            .gte("created_at", date_start)
            .lte("created_at", date_end)
            .eq("status", "completed")
            .eq("discarded", False)
            .not_.is_("communication_feedback", "null")
            .execute()
        )
    except Exception as e:
        print(f"[DailyReport] Error querying conversations: {e}")
        return {"users_processed": 0, "reports_generated": 0, "errors": [str(e)]}

    if not result.data:
        print("[DailyReport] No conversations with feedback found for today")
        return {"users_processed": 0, "reports_generated": 0, "errors": []}

    # Get unique user IDs
    user_ids = list(set(row["user_id"] for row in result.data))
    print(f"[DailyReport] Found {len(user_ids)} users with conversations today")

    reports_generated = 0
    errors = []

    for user_id in user_ids:
        try:
            success = await _generate_single_user_report(
                supabase, user_id, report_date, date_start, date_end
            )
            if success:
                reports_generated += 1
        except Exception as e:
            error_msg = f"User {user_id}: {e}"
            print(f"[DailyReport] Error: {error_msg}")
            errors.append(error_msg)

    summary = {
        "users_processed": len(user_ids),
        "reports_generated": reports_generated,
        "errors": errors,
        "report_date": report_date,
    }
    print(f"[DailyReport] Complete: {summary}")
    return summary


async def generate_daily_report_for_user(user_id: str, target_date: Optional[str] = None) -> dict:
    """Generate a daily report for a single user.

    Args:
        user_id: The maity.users.id for the user.
        target_date: Date string YYYY-MM-DD. Defaults to today in Mexico time.

    Returns:
        Dict with success, report_date, user_id, and error (if any).
    """
    supabase = get_supabase()

    if target_date:
        report_date = target_date
    else:
        now_utc = datetime.now(timezone.utc)
        mexico_time = now_utc + timedelta(hours=MEXICO_UTC_OFFSET)
        report_date = mexico_time.strftime("%Y-%m-%d")

    date_start = f"{report_date}T00:00:00"
    date_end = f"{report_date}T23:59:59"

    try:
        success = await _generate_single_user_report(
            supabase, user_id, report_date, date_start, date_end
        )
        return {
            "success": success,
            "report_date": report_date,
            "user_id": user_id,
            "error": None if success else "No conversations with feedback found for this date",
        }
    except Exception as e:
        return {
            "success": False,
            "report_date": report_date,
            "user_id": user_id,
            "error": str(e),
        }


async def _generate_single_user_report(
    supabase, user_id: str, report_date: str, date_start: str, date_end: str
) -> bool:
    """Generate a daily report for a single user.

    Returns True if report was generated successfully.
    """
    # Fetch today's conversations with communication_feedback
    convos = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("id, communication_feedback, words_count, duration_seconds")
        .eq("user_id", user_id)
        .gte("created_at", date_start)
        .lte("created_at", date_end)
        .eq("status", "completed")
        .eq("discarded", False)
        .not_.is_("communication_feedback", "null")
        .execute()
    )

    if not convos.data:
        return False

    # Aggregate counters from all conversations
    total_words = 0
    total_duration = 0
    all_filler_words = {}
    total_filler_count = 0
    total_pero_count = 0
    all_objection_words = {}
    all_objections_received = []
    all_objections_made = []
    all_strengths = []
    all_areas_to_improve = []
    conversation_ids = []

    for convo in convos.data:
        conversation_ids.append(convo["id"])
        total_words += convo.get("words_count") or 0
        total_duration += convo.get("duration_seconds") or 0

        feedback = convo.get("communication_feedback")
        if not feedback or not isinstance(feedback, dict):
            continue

        counters = feedback.get("counters", {})
        if counters:
            # Filler words
            filler = counters.get("filler_words", {})
            if isinstance(filler, dict):
                for word, count in filler.items():
                    all_filler_words[word] = all_filler_words.get(word, 0) + (count if isinstance(count, int) else 0)
                    total_filler_count += count if isinstance(count, int) else 0

            # Pero count
            total_pero_count += counters.get("pero_count", 0) if isinstance(counters.get("pero_count"), int) else 0

            # Objection words
            obj_words = counters.get("objection_words", {})
            if isinstance(obj_words, dict):
                for word, count in obj_words.items():
                    all_objection_words[word] = all_objection_words.get(word, 0) + (count if isinstance(count, int) else 0)

            # Objections lists
            received = counters.get("objections_received", [])
            if isinstance(received, list):
                all_objections_received.extend(received[:5])
            made = counters.get("objections_made", [])
            if isinstance(made, list):
                all_objections_made.extend(made[:5])

        # Strengths & areas
        strengths = feedback.get("strengths", [])
        if isinstance(strengths, list):
            all_strengths.extend(strengths)
        areas = feedback.get("areas_to_improve", [])
        if isinstance(areas, list):
            all_areas_to_improve.extend(areas)

    # Limit lists
    all_objections_received = all_objections_received[:10]
    all_objections_made = all_objections_made[:10]

    # Get previous report for trend comparison
    trend_context = ""
    previous_report = None
    try:
        prev = (
            supabase.schema("maity")
            .table("daily_communication_reports")
            .select("score_overall, score_clarity, score_structure, score_calls_to_action, score_objection_handling, report_date")
            .eq("user_id", user_id)
            .lt("report_date", report_date)
            .order("report_date", desc=True)
            .limit(1)
            .execute()
        )
        if prev.data:
            previous_report = prev.data[0]
            trend_context = f"""REPORTE ANTERIOR ({previous_report['report_date']}):
- Score general: {previous_report['score_overall']}
- Claridad: {previous_report['score_clarity']}
- Estructura: {previous_report['score_structure']}
- Llamados a acción: {previous_report['score_calls_to_action']}
- Manejo de objeciones: {previous_report['score_objection_handling']}
Compara con estos scores para determinar la tendencia."""
    except Exception as e:
        print(f"[DailyReport] Could not fetch previous report: {e}")
        trend_context = "No hay reporte previo. Tendencia: first_report"

    # Call OpenAI for evaluation
    evaluation = await _call_openai_evaluation(
        conversations_analyzed=len(convos.data),
        total_words=total_words,
        total_duration_minutes=round(total_duration / 60),
        filler_words=json.dumps(all_filler_words, ensure_ascii=False),
        total_filler_count=total_filler_count,
        pero_count=total_pero_count,
        objection_words=json.dumps(all_objection_words, ensure_ascii=False),
        objections_received=json.dumps(all_objections_received, ensure_ascii=False),
        objections_made=json.dumps(all_objections_made, ensure_ascii=False),
        strengths=json.dumps(all_strengths[:10], ensure_ascii=False),
        areas_to_improve=json.dumps(all_areas_to_improve[:10], ensure_ascii=False),
        trend_context=trend_context,
    )

    if not evaluation:
        print(f"[DailyReport] OpenAI evaluation failed for user {user_id}")
        return False

    # Get auth_id for this user
    auth_id = None
    try:
        user_data = (
            supabase.schema("maity")
            .table("users")
            .select("auth_id")
            .eq("id", user_id)
            .single()
            .execute()
        )
        if user_data.data:
            auth_id = user_data.data.get("auth_id")
    except Exception:
        pass

    # Determine trend
    trend = evaluation.get("trend", "first_report")
    trend_details = None
    if previous_report:
        prev_overall = float(previous_report.get("score_overall", 0))
        curr_overall = float(evaluation.get("score_overall", 0))
        change = curr_overall - prev_overall
        trend_details = {
            "previous_overall": prev_overall,
            "change": round(change, 1),
        }
        # Override AI trend with calculated trend
        if abs(change) < 0.5:
            trend = "stable"
        elif change > 0:
            trend = "improving"
        else:
            trend = "declining"
    else:
        trend = "first_report"

    # Upsert into database
    report_data = {
        "user_id": user_id,
        "auth_id": auth_id,
        "report_date": report_date,
        "conversations_analyzed": len(convos.data),
        "total_words_analyzed": total_words,
        "total_duration_seconds": total_duration,
        "total_filler_words": all_filler_words,
        "total_filler_count": total_filler_count,
        "total_pero_count": total_pero_count,
        "total_objection_words": all_objection_words,
        "objections_received": all_objections_received,
        "objections_made": all_objections_made,
        "score_clarity": float(evaluation.get("score_clarity", 0)),
        "score_structure": float(evaluation.get("score_structure", 0)),
        "score_calls_to_action": float(evaluation.get("score_calls_to_action", 0)),
        "score_objection_handling": float(evaluation.get("score_objection_handling", 0)),
        "score_overall": float(evaluation.get("score_overall", 0)),
        "top_strengths": evaluation.get("top_strengths", [])[:5],
        "top_areas_to_improve": evaluation.get("top_areas_to_improve", [])[:5],
        "daily_summary": evaluation.get("daily_summary", "")[:500],
        "recommendations": evaluation.get("recommendations", [])[:4],
        "trend": trend,
        "trend_details": trend_details,
        "conversation_ids": conversation_ids,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    try:
        supabase.schema("maity").table("daily_communication_reports").upsert(
            report_data,
            on_conflict="user_id,report_date",
        ).execute()
        print(f"[DailyReport] Report saved for user {user_id}, date {report_date}, score {evaluation.get('score_overall', 0)}")
        return True
    except Exception as e:
        print(f"[DailyReport] Error saving report: {e}")
        return False


async def _call_openai_evaluation(**kwargs) -> Optional[dict]:
    """Call OpenAI to generate daily evaluation scores.

    Returns parsed dict or None on error.
    """
    prompt = DAILY_EVALUATION_PROMPT.format(**kwargs)

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        response = await asyncio.wait_for(
            client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {
                        "role": "system",
                        "content": "Eres un coach de comunicación profesional que evalúa el desempeño diario. Responde SOLO con JSON válido, sin markdown ni explicaciones.",
                    },
                    {
                        "role": "user",
                        "content": prompt,
                    },
                ],
                max_tokens=800,
                temperature=0.7,
            ),
            timeout=30.0,
        )

        content = response.choices[0].message.content
        if content:
            return parse_json_from_llm(content)

    except asyncio.TimeoutError:
        print("[DailyReport] OpenAI timeout after 30s")
    except json.JSONDecodeError as e:
        print(f"[DailyReport] JSON parse error: {e}")
    except Exception as e:
        print(f"[DailyReport] OpenAI error: {e}")

    return None
