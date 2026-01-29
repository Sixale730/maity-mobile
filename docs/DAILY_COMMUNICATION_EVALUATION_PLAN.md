# Plan: Evaluación Diaria Automática de Comunicación + Notificaciones

## Resumen Ejecutivo

Actualmente Maity genera una evaluación de comunicación **por conversación** (fortalezas, áreas de mejora, observaciones, contadores de muletillas). Este plan propone crear un sistema de **evaluación diaria automática** que:

1. Se ejecute automáticamente cada noche
2. Agregue y analice todas las conversaciones del día con OpenAI
3. Almacene el resultado en una tabla dedicada para crear un **histórico diario**
4. Notifique al usuario cuando su análisis está listo
5. Exponga los datos para consumo en la **plataforma web**

**Valor**: El usuario obtiene un "reporte diario" de su comunicación sin hacer nada, y la web puede mostrar tendencias y progreso a lo largo del tiempo.

---

## Estado Actual

### Evaluación por Conversación (existente)

```
Conversación guardada
       ↓
POST /v1/omi/conversations/store (api/routers/omi.py:183-218)
       ↓
analyze_communication(segments) → OpenAI gpt-4o-mini
       ↓
Resultado → omi_conversations.communication_feedback (JSONB)
```

**Modelo actual** (`api/models/communication.py`):
```python
CommunicationFeedback:
  strengths: List[str]           # 2-5 fortalezas
  areas_to_improve: List[str]    # 2-5 áreas de mejora
  observations:
    clarity: str
    structure: str
    calls_to_action: str
    objections: str
  summary: str
  counters:
    pero_count: int
    objection_words: Dict[str, int]
    filler_words: Dict[str, int]
    objections_received: List[str]
    objections_made: List[str]
```

**Agregación existente** (`api/routers/communication.py`):
- GET `/v1/communication/feedback?period=monthly` — agrega por frecuencia de fortalezas/áreas
- Limitación: solo cuenta cuántas veces aparece cada fortaleza, no genera un análisis nuevo

### Lo que Falta

| Capacidad | Hoy | Propuesta |
|-----------|-----|-----------|
| Análisis por conversación | ✅ | Se mantiene igual |
| Análisis diario consolidado | ❌ | Nuevo análisis con OpenAI sobre el día completo |
| Ejecución automática | ❌ | Vercel Cron Job diario |
| Histórico por día | ❌ | Nueva tabla `daily_communication_reports` |
| Notificación al usuario | ❌ | Push notification + in-app |
| Consumo web | ❌ Parcial | Endpoints dedicados + tabla compartida en Supabase |

---

## Arquitectura Propuesta

```
                          ┌──────────────────────────────┐
                          │      Vercel Cron Job         │
                          │  (diario, ~2:00 AM UTC)      │
                          └──────────────┬───────────────┘
                                         │
                                         ▼
                          ┌──────────────────────────────┐
                          │  POST /v1/daily-report/      │
                          │       generate               │
                          │                              │
                          │  1. Obtener usuarios activos │
                          │  2. Por cada usuario:        │
                          │     a. Buscar conversaciones  │
                          │        del día con feedback   │
                          │     b. Buscar transcripciones │
                          │     c. Llamar OpenAI con      │
                          │        prompt de análisis     │
                          │        diario                 │
                          │     d. Guardar en tabla       │
                          │        daily_communication_   │
                          │        reports                │
                          │     e. Enviar push            │
                          │        notification           │
                          └──────────────┬───────────────┘
                                         │
                          ┌──────────────┴───────────────┐
                          │                              │
                          ▼                              ▼
               ┌────────────────────┐       ┌────────────────────┐
               │  Supabase          │       │  Push Notification │
               │  daily_communi-    │       │  (FCM / APNs)      │
               │  cation_reports    │       │                    │
               └────────┬───────────┘       └────────────────────┘
                        │
              ┌─────────┴─────────┐
              │                   │
              ▼                   ▼
     ┌─────────────┐    ┌─────────────────┐
     │ Flutter App │    │  Web Platform   │
     │ (histórico) │    │  (dashboard)    │
     └─────────────┘    └─────────────────┘
```

---

## 1. Base de Datos

### Nueva Tabla: `maity.daily_communication_reports`

```sql
CREATE TABLE maity.daily_communication_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES maity.users(id),
  auth_id UUID NOT NULL REFERENCES auth.users(id),
  report_date DATE NOT NULL,

  -- Análisis del día (generado por OpenAI)
  strengths JSONB NOT NULL DEFAULT '[]',          -- List[str], top fortalezas del día
  areas_to_improve JSONB NOT NULL DEFAULT '[]',   -- List[str], top áreas de mejora
  observations JSONB NOT NULL DEFAULT '{}',       -- {clarity, structure, calls_to_action, objections}
  summary TEXT NOT NULL DEFAULT '',                -- Resumen del día en 2-3 oraciones
  counters JSONB DEFAULT NULL,                    -- Contadores agregados del día

  -- Métricas cuantitativas del día
  conversations_analyzed INT NOT NULL DEFAULT 0,
  total_words_analyzed INT NOT NULL DEFAULT 0,
  total_duration_seconds INT NOT NULL DEFAULT 0,

  -- Scores numéricos para gráficas en web (0.0 - 10.0)
  score_clarity FLOAT DEFAULT NULL,
  score_structure FLOAT DEFAULT NULL,
  score_calls_to_action FLOAT DEFAULT NULL,
  score_objection_handling FLOAT DEFAULT NULL,
  score_overall FLOAT DEFAULT NULL,

  -- Comparación con día anterior
  trend TEXT DEFAULT NULL,                         -- 'improving', 'stable', 'declining'
  trend_details TEXT DEFAULT NULL,                 -- Descripción breve de la tendencia

  -- Metadata
  notification_sent BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Restricción: un reporte por usuario por día
  UNIQUE(user_id, report_date)
);

-- Índices
CREATE INDEX idx_daily_reports_user_date
  ON maity.daily_communication_reports(user_id, report_date DESC);

CREATE INDEX idx_daily_reports_auth_date
  ON maity.daily_communication_reports(auth_id, report_date DESC);

-- RLS
ALTER TABLE maity.daily_communication_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own daily reports"
  ON maity.daily_communication_reports FOR SELECT
  USING (auth.uid() = auth_id);

-- Trigger para updated_at
CREATE TRIGGER update_daily_reports_updated_at
  BEFORE UPDATE ON maity.daily_communication_reports
  FOR EACH ROW EXECUTE FUNCTION maity.update_updated_at();
```

### Scores Numéricos

Los scores (0-10) permiten a la web generar gráficas de tendencia:

| Score | Significado |
|-------|-------------|
| 0-3 | Necesita mejora significativa |
| 4-6 | Adecuado, con áreas de oportunidad |
| 7-8 | Bueno |
| 9-10 | Excelente |

### Contadores Agregados del Día

```json
{
  "total_pero_count": 15,
  "avg_pero_per_conversation": 3.0,
  "total_filler_words": {"este": 8, "o sea": 5, "bueno": 12},
  "avg_fillers_per_conversation": 5.0,
  "total_objection_words": {"pero": 15, "sin embargo": 3},
  "top_objections_received": ["es muy caro", "no tenemos presupuesto"],
  "top_objections_made": ["pero necesito más info", "sin embargo creo que..."]
}
```

---

## 2. Backend: Servicio de Reporte Diario

### 2.1 Modelo de Datos

**Nuevo archivo**: `api/models/daily_report.py`

```python
from typing import List, Optional, Dict
from pydantic import BaseModel, Field
from datetime import date


class DailyCounters(BaseModel):
    """Contadores agregados del día"""
    total_pero_count: int = 0
    avg_pero_per_conversation: float = 0.0
    total_filler_words: Dict[str, int] = Field(default_factory=dict)
    avg_fillers_per_conversation: float = 0.0
    total_objection_words: Dict[str, int] = Field(default_factory=dict)
    top_objections_received: List[str] = Field(default_factory=list)
    top_objections_made: List[str] = Field(default_factory=list)


class DailyScores(BaseModel):
    """Scores numéricos para gráficas (0.0 - 10.0)"""
    clarity: float = 0.0
    structure: float = 0.0
    calls_to_action: float = 0.0
    objection_handling: float = 0.0
    overall: float = 0.0


class DailyCommunicationReport(BaseModel):
    """Reporte diario de comunicación"""
    id: Optional[str] = None
    user_id: str
    report_date: str  # YYYY-MM-DD

    # Análisis cualitativo
    strengths: List[str] = Field(default_factory=list)
    areas_to_improve: List[str] = Field(default_factory=list)
    observations: dict = Field(default_factory=dict)  # {clarity, structure, ...}
    summary: str = ""
    counters: Optional[DailyCounters] = None

    # Métricas cuantitativas
    conversations_analyzed: int = 0
    total_words_analyzed: int = 0
    total_duration_seconds: int = 0

    # Scores
    scores: Optional[DailyScores] = None

    # Tendencia
    trend: Optional[str] = None           # improving, stable, declining
    trend_details: Optional[str] = None


class DailyReportHistoryResponse(BaseModel):
    """Respuesta con histórico de reportes diarios"""
    user_id: str
    reports: List[DailyCommunicationReport] = Field(default_factory=list)
    period: str = "monthly"
    total_days_with_reports: int = 0
```

### 2.2 Servicio de Generación

**Nuevo archivo**: `api/services/daily_report_generator.py`

```python
"""Servicio para generar reportes diarios de comunicación"""
import json
import os
from datetime import date, datetime, timedelta
from typing import List, Optional, Dict
import openai

from ..models.communication import CommunicationFeedback, CommunicationCounters
from ..models.daily_report import (
    DailyCommunicationReport, DailyCounters, DailyScores
)
from ..services.supabase_client import get_supabase


DAILY_ANALYSIS_PROMPT = """Eres un coach de comunicación analizando el desempeño diario de un usuario.

A continuación tienes los análisis individuales de {conversations_count} conversaciones del día {report_date}.

ANÁLISIS POR CONVERSACIÓN:
{conversations_feedback}

CONTADORES AGREGADOS DEL DÍA:
- Total "peros": {total_pero_count}
- Muletillas: {filler_words_summary}
- Palabras de objeción: {objection_words_summary}

{previous_report_context}

Genera un REPORTE DIARIO CONSOLIDADO que:
1. Identifique patrones del día (no repitas lo de cada conversación, sintetiza)
2. Destaque las 3-5 fortalezas más consistentes
3. Identifique 3-5 áreas de mejora prioritarias
4. Dé observaciones consolidadas por categoría
5. Asigne SCORES numéricos de 0.0 a 10.0 para cada categoría
6. Compare con el día anterior si hay contexto (trend)
7. Escriba un resumen de 2-3 oraciones del día

Responde ÚNICAMENTE en JSON válido:
{{
  "strengths": ["fortaleza 1", "fortaleza 2", "fortaleza 3"],
  "areas_to_improve": ["área 1", "área 2", "área 3"],
  "observations": {{
    "clarity": "Observación consolidada sobre claridad...",
    "structure": "Observación consolidada sobre estructura...",
    "calls_to_action": "Observación sobre llamados a acción...",
    "objections": "Observación sobre manejo de objeciones..."
  }},
  "scores": {{
    "clarity": 7.5,
    "structure": 6.0,
    "calls_to_action": 5.5,
    "objection_handling": 8.0,
    "overall": 6.8
  }},
  "summary": "Resumen del día en 2-3 oraciones...",
  "trend": "improving|stable|declining",
  "trend_details": "Breve explicación de la tendencia vs ayer..."
}}"""


async def generate_daily_report(
    user_id: str,
    auth_id: str,
    report_date: date,
) -> Optional[DailyCommunicationReport]:
    """
    Genera el reporte diario de comunicación para un usuario.

    1. Obtiene conversaciones del día con communication_feedback
    2. Agrega contadores
    3. Obtiene reporte del día anterior (para tendencia)
    4. Llama a OpenAI para análisis consolidado
    5. Guarda en daily_communication_reports
    """
    supabase = get_supabase()

    # 1. Obtener conversaciones del día con feedback
    start_of_day = datetime.combine(report_date, datetime.min.time())
    end_of_day = datetime.combine(report_date + timedelta(days=1), datetime.min.time())

    conversations = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("id, title, communication_feedback, words_count, duration_seconds")
        .eq("user_id", user_id)
        .eq("deleted", False)
        .not_.is_("communication_feedback", "null")
        .gte("created_at", start_of_day.isoformat())
        .lt("created_at", end_of_day.isoformat())
        .order("created_at")
        .execute()
    ).data or []

    if not conversations:
        return None  # No hay conversaciones para analizar

    # 2. Agregar datos
    feedbacks = []
    total_words = 0
    total_duration = 0
    total_pero = 0
    all_filler_words: Dict[str, int] = {}
    all_objection_words: Dict[str, int] = {}
    all_objections_received: List[str] = []
    all_objections_made: List[str] = []

    conversations_summary_parts = []

    for conv in conversations:
        fb_data = conv.get("communication_feedback", {})
        if not fb_data or not isinstance(fb_data, dict):
            continue

        total_words += conv.get("words_count", 0) or 0
        total_duration += conv.get("duration_seconds", 0) or 0

        # Agregar contadores
        counters = fb_data.get("counters", {}) or {}
        total_pero += counters.get("pero_count", 0)

        for word, count in counters.get("filler_words", {}).items():
            all_filler_words[word] = all_filler_words.get(word, 0) + count

        for word, count in counters.get("objection_words", {}).items():
            all_objection_words[word] = all_objection_words.get(word, 0) + count

        for obj in counters.get("objections_received", []):
            if obj not in all_objections_received:
                all_objections_received.append(obj)

        for obj in counters.get("objections_made", []):
            if obj not in all_objections_made:
                all_objections_made.append(obj)

        # Resumen para el prompt
        title = conv.get("title", "Sin título")
        strengths = fb_data.get("strengths", [])
        areas = fb_data.get("areas_to_improve", [])
        summary = fb_data.get("summary", "")
        conversations_summary_parts.append(
            f"### {title}\n"
            f"- Fortalezas: {', '.join(strengths)}\n"
            f"- Áreas de mejora: {', '.join(areas)}\n"
            f"- Resumen: {summary}"
        )

    conversations_count = len(conversations)

    # 3. Obtener reporte del día anterior (para tendencia)
    previous_date = report_date - timedelta(days=1)
    prev_report = (
        supabase.schema("maity")
        .table("daily_communication_reports")
        .select("summary, score_overall, score_clarity, score_structure")
        .eq("user_id", user_id)
        .eq("report_date", previous_date.isoformat())
        .limit(1)
        .execute()
    ).data

    previous_context = ""
    if prev_report:
        prev = prev_report[0]
        previous_context = (
            f"CONTEXTO DEL DÍA ANTERIOR ({previous_date}):\n"
            f"- Resumen: {prev.get('summary', 'N/A')}\n"
            f"- Score general: {prev.get('score_overall', 'N/A')}/10\n"
            f"- Claridad: {prev.get('score_clarity', 'N/A')}/10\n"
            f"Compara el desempeño de hoy con el de ayer."
        )
    else:
        previous_context = "No hay reporte del día anterior (primer análisis o sin actividad ayer)."

    # 4. Llamar a OpenAI
    filler_summary = ", ".join(
        f'"{w}": {c}' for w, c in
        sorted(all_filler_words.items(), key=lambda x: -x[1])[:10]
    ) or "ninguna detectada"

    objection_summary = ", ".join(
        f'"{w}": {c}' for w, c in
        sorted(all_objection_words.items(), key=lambda x: -x[1])[:5]
    ) or "ninguna detectada"

    prompt = DAILY_ANALYSIS_PROMPT.format(
        conversations_count=conversations_count,
        report_date=report_date.isoformat(),
        conversations_feedback="\n\n".join(conversations_summary_parts),
        total_pero_count=total_pero,
        filler_words_summary=filler_summary,
        objection_words_summary=objection_summary,
        previous_report_context=previous_context,
    )

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Eres un coach de comunicación que genera reportes "
                        "diarios consolidados. Responde SOLO con JSON válido."
                    )
                },
                {"role": "user", "content": prompt}
            ],
            max_tokens=1000,
            temperature=0.7,
        )

        content = response.choices[0].message.content
        if not content:
            return None

        # Parsear respuesta
        json_str = content.strip()
        if json_str.startswith("```"):
            json_str = json_str.split("```")[1]
            if json_str.startswith("json"):
                json_str = json_str[4:]
            json_str = json_str.strip()

        data = json.loads(json_str)

    except Exception as e:
        print(f"[DailyReport] OpenAI error for user {user_id}: {e}")
        return None

    # 5. Construir contadores agregados
    daily_counters = DailyCounters(
        total_pero_count=total_pero,
        avg_pero_per_conversation=round(total_pero / max(conversations_count, 1), 1),
        total_filler_words=all_filler_words,
        avg_fillers_per_conversation=round(
            sum(all_filler_words.values()) / max(conversations_count, 1), 1
        ),
        total_objection_words=all_objection_words,
        top_objections_received=all_objections_received[:5],
        top_objections_made=all_objections_made[:5],
    )

    # 6. Extraer scores
    scores_data = data.get("scores", {})
    scores = DailyScores(
        clarity=min(float(scores_data.get("clarity", 0)), 10.0),
        structure=min(float(scores_data.get("structure", 0)), 10.0),
        calls_to_action=min(float(scores_data.get("calls_to_action", 0)), 10.0),
        objection_handling=min(float(scores_data.get("objection_handling", 0)), 10.0),
        overall=min(float(scores_data.get("overall", 0)), 10.0),
    )

    # 7. Guardar en Supabase (upsert por user_id + report_date)
    report_row = {
        "user_id": user_id,
        "auth_id": auth_id,
        "report_date": report_date.isoformat(),
        "strengths": data.get("strengths", [])[:5],
        "areas_to_improve": data.get("areas_to_improve", [])[:5],
        "observations": data.get("observations", {}),
        "summary": data.get("summary", "")[:500],
        "counters": daily_counters.dict(),
        "conversations_analyzed": conversations_count,
        "total_words_analyzed": total_words,
        "total_duration_seconds": total_duration,
        "score_clarity": scores.clarity,
        "score_structure": scores.structure,
        "score_calls_to_action": scores.calls_to_action,
        "score_objection_handling": scores.objection_handling,
        "score_overall": scores.overall,
        "trend": data.get("trend"),
        "trend_details": data.get("trend_details"),
        "notification_sent": False,
    }

    result = (
        supabase.schema("maity")
        .table("daily_communication_reports")
        .upsert(report_row, on_conflict="user_id,report_date")
        .execute()
    )

    report_id = result.data[0]["id"] if result.data else None

    return DailyCommunicationReport(
        id=report_id,
        user_id=user_id,
        report_date=report_date.isoformat(),
        strengths=data.get("strengths", [])[:5],
        areas_to_improve=data.get("areas_to_improve", [])[:5],
        observations=data.get("observations", {}),
        summary=data.get("summary", ""),
        counters=daily_counters,
        conversations_analyzed=conversations_count,
        total_words_analyzed=total_words,
        total_duration_seconds=total_duration,
        scores=scores,
        trend=data.get("trend"),
        trend_details=data.get("trend_details"),
    )


async def get_active_users_for_date(report_date: date) -> List[dict]:
    """
    Obtiene usuarios que tuvieron conversaciones con feedback en la fecha dada.
    Retorna lista de {user_id, auth_id}.
    """
    supabase = get_supabase()

    start_of_day = datetime.combine(report_date, datetime.min.time())
    end_of_day = datetime.combine(report_date + timedelta(days=1), datetime.min.time())

    result = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("user_id")
        .eq("deleted", False)
        .not_.is_("communication_feedback", "null")
        .gte("created_at", start_of_day.isoformat())
        .lt("created_at", end_of_day.isoformat())
        .execute()
    )

    if not result.data:
        return []

    # Obtener user_ids únicos
    unique_user_ids = list(set(conv["user_id"] for conv in result.data))

    # Obtener auth_ids correspondientes
    users_result = (
        supabase.schema("maity")
        .table("users")
        .select("id, auth_id")
        .in_("id", unique_user_ids)
        .execute()
    )

    return users_result.data or []
```

### 2.3 Router de Reportes Diarios

**Nuevo archivo**: `api/routers/daily_reports.py`

```python
"""Router para reportes diarios de comunicación"""
from datetime import date, datetime, timedelta
from typing import Optional, List
from fastapi import APIRouter, HTTPException, Query, Path, Depends

from ..models.daily_report import (
    DailyCommunicationReport,
    DailyReportHistoryResponse,
)
from ..services.daily_report_generator import (
    generate_daily_report,
    get_active_users_for_date,
)
from ..services.supabase_client import get_supabase
from ..services.supabase_auth import optional_auth_user_id

router = APIRouter(prefix="/v1/daily-report", tags=["daily-reports"])


# ============ Cron Job Endpoint ============

@router.post("/generate")
async def generate_daily_reports(
    target_date: Optional[str] = Query(
        None,
        description="Fecha a procesar (YYYY-MM-DD). Default: ayer"
    ),
    user_id: Optional[str] = Query(
        None,
        description="Generar solo para un usuario específico"
    ),
    cron_secret: Optional[str] = Query(None, description="Secret para Vercel Cron"),
):
    """
    Genera reportes diarios para todos los usuarios activos.

    Este endpoint es llamado por Vercel Cron Job diariamente.
    También puede ser invocado manualmente para regenerar reportes.
    """
    # Validar cron secret en producción
    # if cron_secret != os.getenv("CRON_SECRET"):
    #     raise HTTPException(status_code=401, detail="Invalid cron secret")

    report_date = date.fromisoformat(target_date) if target_date else date.today() - timedelta(days=1)

    if user_id:
        # Generar para un solo usuario
        supabase = get_supabase()
        user = (
            supabase.schema("maity")
            .table("users").select("id, auth_id")
            .eq("id", user_id).single().execute()
        ).data

        if not user:
            raise HTTPException(status_code=404, detail="User not found")

        report = await generate_daily_report(
            user_id=user["id"],
            auth_id=user["auth_id"],
            report_date=report_date,
        )

        return {
            "date": report_date.isoformat(),
            "reports_generated": 1 if report else 0,
            "users_processed": 1,
            "results": [
                {
                    "user_id": user_id,
                    "generated": report is not None,
                    "conversations": report.conversations_analyzed if report else 0,
                }
            ]
        }

    # Generar para todos los usuarios activos
    active_users = await get_active_users_for_date(report_date)

    results = []
    reports_generated = 0

    for user in active_users:
        try:
            report = await generate_daily_report(
                user_id=user["id"],
                auth_id=user["auth_id"],
                report_date=report_date,
            )
            if report:
                reports_generated += 1
                # TODO: Enviar push notification aquí
            results.append({
                "user_id": user["id"],
                "generated": report is not None,
                "conversations": report.conversations_analyzed if report else 0,
            })
        except Exception as e:
            print(f"[DailyReport] Error for user {user['id']}: {e}")
            results.append({
                "user_id": user["id"],
                "generated": False,
                "error": str(e),
            })

    return {
        "date": report_date.isoformat(),
        "reports_generated": reports_generated,
        "users_processed": len(active_users),
        "results": results,
    }


# ============ Consulta de Reportes ============

@router.get("/latest")
async def get_latest_report(
    user_id: str = Query(..., description="User ID"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Obtener el reporte diario más reciente del usuario."""
    supabase = get_supabase()

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
        raise HTTPException(status_code=404, detail="No daily reports found")

    return result.data[0]


@router.get("/history")
async def get_report_history(
    user_id: str = Query(..., description="User ID"),
    period: str = Query("monthly", description="weekly, monthly, yearly"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Obtener histórico de reportes diarios.

    Usado por la web para gráficas de tendencia.
    """
    supabase = get_supabase()

    now = datetime.utcnow()
    if period == "weekly":
        start_date = now - timedelta(days=7)
    elif period == "monthly":
        start_date = now - timedelta(days=30)
    elif period == "yearly":
        start_date = now - timedelta(days=365)
    else:
        start_date = now - timedelta(days=30)

    result = (
        supabase.schema("maity")
        .table("daily_communication_reports")
        .select(
            "id, report_date, summary, "
            "score_clarity, score_structure, score_calls_to_action, "
            "score_objection_handling, score_overall, "
            "conversations_analyzed, total_words_analyzed, "
            "trend, trend_details, strengths, areas_to_improve"
        )
        .eq("user_id", user_id)
        .gte("report_date", start_date.date().isoformat())
        .order("report_date", desc=True)
        .execute()
    )

    return {
        "user_id": user_id,
        "period": period,
        "total_days_with_reports": len(result.data) if result.data else 0,
        "reports": result.data or [],
    }


@router.get("/{report_date}")
async def get_report_by_date(
    report_date: str = Path(..., description="Fecha del reporte (YYYY-MM-DD)"),
    user_id: str = Query(..., description="User ID"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Obtener reporte de un día específico."""
    supabase = get_supabase()

    result = (
        supabase.schema("maity")
        .table("daily_communication_reports")
        .select("*")
        .eq("user_id", user_id)
        .eq("report_date", report_date)
        .limit(1)
        .execute()
    )

    if not result.data:
        raise HTTPException(status_code=404, detail="Report not found for this date")

    return result.data[0]
```

### 2.4 Registrar Router

**Modificar**: `api/index.py`

```python
# Agregar import
from .routers.daily_reports import router as daily_reports_router

# Agregar al app
app.include_router(daily_reports_router)
```

---

## 3. Ejecución Automática (Vercel Cron)

### 3.1 Configuración Vercel Cron

**Nuevo archivo**: `vercel.json` (agregar sección crons)

```json
{
  "crons": [
    {
      "path": "/v1/daily-report/generate?cron_secret=${CRON_SECRET}",
      "schedule": "0 8 * * *"
    }
  ]
}
```

**Horario**: `0 8 * * *` = 8:00 AM UTC diario = ~2:00 AM CST (México).

Esto asegura que todas las conversaciones del día anterior ya estén guardadas antes de procesarlas.

### 3.2 Variable de Entorno

Agregar en Vercel Dashboard:
```
CRON_SECRET=<random-secret-string>
```

### 3.3 Alternativa: Supabase Edge Function + pg_cron

Si se prefiere ejecutar desde Supabase en lugar de Vercel:

```sql
-- Habilitar pg_cron
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Programar llamada HTTP diaria
SELECT cron.schedule(
  'daily-communication-report',
  '0 8 * * *',
  $$
  SELECT net.http_post(
    url := 'https://maity-mobile.vercel.app/v1/daily-report/generate',
    headers := jsonb_build_object(
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'cron_secret', current_setting('app.cron_secret')
    )
  )
  $$
);
```

---

## 4. Sistema de Notificaciones

### 4.1 Backend: Enviar Push Notification

**Nuevo archivo**: `api/services/push_notification_service.py`

```python
"""Servicio de push notifications via FCM"""
import os
from typing import Optional
import httpx

# Firebase Cloud Messaging
FCM_SERVER_KEY = os.getenv("FCM_SERVER_KEY")


async def send_daily_report_notification(
    user_id: str,
    report_date: str,
    summary: str,
    score_overall: float,
):
    """
    Enviar push notification informando que el reporte diario está listo.
    """
    from ..services.supabase_client import get_supabase
    supabase = get_supabase()

    # Obtener FCM token del usuario
    result = (
        supabase.schema("maity")
        .table("user_devices")
        .select("fcm_token")
        .eq("user_id", user_id)
        .eq("is_active", True)
        .execute()
    )

    if not result.data:
        return False

    tokens = [d["fcm_token"] for d in result.data if d.get("fcm_token")]
    if not tokens:
        return False

    # Construir notificación
    title = "📊 Tu reporte diario está listo"
    body = f"Score: {score_overall}/10 - {summary[:100]}"

    for token in tokens:
        try:
            async with httpx.AsyncClient() as client:
                await client.post(
                    "https://fcm.googleapis.com/fcm/send",
                    headers={
                        "Authorization": f"key={FCM_SERVER_KEY}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "to": token,
                        "notification": {
                            "title": title,
                            "body": body,
                        },
                        "data": {
                            "type": "daily_report",
                            "report_date": report_date,
                            "navigate_to": "daily_report",
                        },
                    },
                )
        except Exception as e:
            print(f"[Push] Error sending to {user_id}: {e}")

    # Marcar notificación como enviada
    supabase.schema("maity").table("daily_communication_reports").update(
        {"notification_sent": True}
    ).eq("user_id", user_id).eq("report_date", report_date).execute()

    return True
```

### 4.2 Tabla de Dispositivos (si no existe)

```sql
CREATE TABLE IF NOT EXISTS maity.user_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES maity.users(id),
  auth_id UUID NOT NULL REFERENCES auth.users(id),
  fcm_token TEXT NOT NULL,
  platform TEXT NOT NULL,  -- 'ios', 'android', 'web'
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(user_id, fcm_token)
);

ALTER TABLE maity.user_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own devices"
  ON maity.user_devices FOR ALL
  USING (auth.uid() = auth_id);
```

### 4.3 Flutter: Registrar Token FCM

**Modificar**: `lib/services/notifications/notification_service.dart`

```dart
import 'package:firebase_messaging/firebase_messaging.dart';

class NotificationService {
  static Future<void> registerFCMToken(String userId) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;

    await MaityApiService.registerDevice(
      userId: userId,
      fcmToken: token,
      platform: Platform.isIOS ? 'ios' : 'android',
    );

    // Escuchar cambios de token
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      MaityApiService.registerDevice(
        userId: userId,
        fcmToken: newToken,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
    });
  }
}
```

### 4.4 Flutter: Manejar Notificación de Reporte Diario

Integración con el sistema existente en `lib/services/notifications.dart`:

```dart
// En NotificationUtil._handleAppLinkOrDeepLink
static void _handleAppLinkOrDeepLink(Map<String, dynamic> payload) async {
  WidgetsFlutterBinding.ensureInitialized();

  String? navigateTo = payload['navigate_to'];
  if (navigateTo == null) return;

  if (navigateTo == 'daily_report') {
    final reportDate = payload['report_date'];
    MyApp.navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => DailyReportPage(reportDate: reportDate),
      ),
    );
    return;
  }

  // Flujo existente...
  MyApp.navigatorKey.currentState?.pushReplacement(
    MaterialPageRoute(builder: (context) => HomePageWrapper(navigateToRoute: navigateTo)),
  );
}
```

### 4.5 Notificación In-App (Banner)

Además del push notification, mostrar un banner en la pantalla principal cuando hay un reporte nuevo sin leer:

```dart
// En ConversationsPage o HomePage
FutureBuilder<bool>(
  future: _checkUnreadDailyReport(),
  builder: (context, snapshot) {
    if (snapshot.data != true) return SizedBox.shrink();

    return Container(
      margin: EdgeInsets.all(12),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(Icons.insights, color: Colors.white),
        title: Text('Tu reporte diario está listo',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text('Toca para ver tu análisis de comunicación',
          style: TextStyle(color: Colors.white70)),
        trailing: Icon(Icons.arrow_forward_ios, color: Colors.white),
        onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => DailyReportPage())),
      ),
    );
  },
)
```

---

## 5. Flutter: Consumo de Reportes Diarios

### 5.1 Servicio API

**Nuevo archivo**: `lib/backend/http/api/daily_reports.dart`

```dart
import 'package:omi/backend/http/shared.dart';

class DailyReportsApi {
  static Future<Map<String, dynamic>?> getLatestReport(String userId) async {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}/v1/daily-report/latest?user_id=$userId',
      method: 'GET',
      headers: {},
      body: '',
    );
    if (response == null || response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>?> getReportHistory({
    required String userId,
    String period = 'monthly',
  }) async {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}/v1/daily-report/history'
           '?user_id=$userId&period=$period',
      method: 'GET',
      headers: {},
      body: '',
    );
    if (response == null || response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>?> getReportByDate({
    required String userId,
    required String date,
  }) async {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}/v1/daily-report/$date?user_id=$userId',
      method: 'GET',
      headers: {},
      body: '',
    );
    if (response == null || response.statusCode != 200) return null;
    return jsonDecode(response.body);
  }
}
```

### 5.2 Provider

**Nuevo archivo**: `lib/providers/daily_report_provider.dart`

```dart
class DailyReportProvider extends ChangeNotifier {
  DailyCommunicationReport? _latestReport;
  List<DailyCommunicationReport> _history = [];
  bool _isLoading = false;
  bool _hasUnreadReport = false;

  DailyCommunicationReport? get latestReport => _latestReport;
  List<DailyCommunicationReport> get history => _history;
  bool get isLoading => _isLoading;
  bool get hasUnreadReport => _hasUnreadReport;

  Future<void> fetchLatestReport(String userId) async { ... }
  Future<void> fetchHistory(String userId, String period) async { ... }
  void markAsRead() { _hasUnreadReport = false; notifyListeners(); }
}
```

### 5.3 Página de Reporte Diario

**Nuevo archivo**: `lib/pages/daily_report/daily_report_page.dart`

Estructura de la página:

```
┌────────────────────────────────┐
│  📊 Reporte Diario             │
│  Martes, 28 de Enero 2026      │
├────────────────────────────────┤
│                                │
│  Score General: 7.2/10  ↑      │
│  ███████████░░░░  (improving)  │
│                                │
├────────────────────────────────┤
│  Scores por Categoría          │
│  ┌──────────────────────────┐  │
│  │ Claridad       8.0  ████│  │
│  │ Estructura     6.5  ███ │  │
│  │ Llamados       5.5  ██  │  │
│  │ Objeciones     7.0  ███ │  │
│  └──────────────────────────┘  │
├────────────────────────────────┤
│  Resumen del Día               │
│  "Hoy mostraste buena          │
│  claridad en tus mensajes..."  │
│                                │
├────────────────────────────────┤
│  ✅ Fortalezas                  │
│  • Comunicación directa        │
│  • Uso de ejemplos concretos   │
│  • Escucha activa              │
│                                │
│  💡 Áreas de Mejora             │
│  • Reducir uso de muletillas   │
│  • Estructurar mejor cierre    │
│                                │
├────────────────────────────────┤
│  📈 Tendencia                   │
│  vs ayer: Mejorando ↑           │
│  "Mayor claridad y menos       │
│   muletillas que ayer"         │
│                                │
├────────────────────────────────┤
│  📊 Métricas del Día            │
│  5 conversaciones analizadas   │
│  2,340 palabras | 45 min       │
│  "peros": 8 | muletillas: 15  │
│                                │
└────────────────────────────────┘
```

---

## 6. Web Platform: Consumo de Datos

La web accede a los mismos datos via Supabase (schema compartido `maity`) o via la API REST.

### 6.1 Endpoints para la Web

| Endpoint | Método | Descripción | Uso Web |
|----------|--------|-------------|---------|
| `/v1/daily-report/latest` | GET | Último reporte | Dashboard |
| `/v1/daily-report/history?period=monthly` | GET | Histórico | Gráficas de tendencia |
| `/v1/daily-report/{date}` | GET | Reporte específico | Detalle por día |

### 6.2 Datos para Gráficas de Tendencia

El endpoint `/history` retorna datos optimizados para gráficas:

```json
{
  "user_id": "abc-123",
  "period": "monthly",
  "total_days_with_reports": 22,
  "reports": [
    {
      "report_date": "2026-01-28",
      "score_overall": 7.2,
      "score_clarity": 8.0,
      "score_structure": 6.5,
      "score_calls_to_action": 5.5,
      "score_objection_handling": 7.0,
      "conversations_analyzed": 5,
      "total_words_analyzed": 2340,
      "trend": "improving",
      "strengths": ["Comunicación directa", "Escucha activa"],
      "areas_to_improve": ["Reducir muletillas"]
    },
    {
      "report_date": "2026-01-27",
      "score_overall": 6.8,
      ...
    }
  ]
}
```

### 6.3 Ejemplo de Gráfica en Web

```
Score General (últimos 30 días)

10 ┤
 9 ┤
 8 ┤          ╭─╮     ╭──╮
 7 ┤    ╭─╮╭─╯ ╰─╮╭─╯  ╰──╮  ╭──
 6 ┤╭──╯ ╰╯     ╰╯        ╰─╯
 5 ┤╯
 4 ┤
   └──────────────────────────────
    1  5  10  15  20  25  30 (días)

── Claridad  ── Estructura  ── Objeciones
```

### 6.4 Query Directa desde Web (Supabase Client)

```typescript
// Web platform - Supabase JS client
const { data } = await supabase
  .schema('maity')
  .from('daily_communication_reports')
  .select(`
    report_date,
    score_overall, score_clarity, score_structure,
    score_calls_to_action, score_objection_handling,
    conversations_analyzed, summary, trend
  `)
  .eq('user_id', userId)
  .gte('report_date', thirtyDaysAgo)
  .order('report_date', { ascending: true });

// Directamente usable para Chart.js, Recharts, etc.
const chartData = data.map(r => ({
  date: r.report_date,
  overall: r.score_overall,
  clarity: r.score_clarity,
  structure: r.score_structure,
}));
```

---

## 7. Checklist de Implementación

### Fase 1: Backend + Base de Datos
- [ ] Crear tabla `daily_communication_reports` en Supabase
- [ ] Crear tabla `user_devices` para FCM tokens (si no existe)
- [ ] Crear RLS policies para ambas tablas
- [ ] Crear `api/models/daily_report.py`
- [ ] Crear `api/services/daily_report_generator.py`
- [ ] Crear `api/routers/daily_reports.py`
- [ ] Registrar router en `api/index.py`
- [ ] Testing manual: generar reporte para un usuario

### Fase 2: Ejecución Automática
- [ ] Configurar Vercel Cron Job en `vercel.json`
- [ ] Agregar `CRON_SECRET` a variables de entorno Vercel
- [ ] Validar que el cron se ejecuta correctamente
- [ ] Agregar logging/monitoreo de ejecuciones del cron
- [ ] Manejar errores y reintentos

### Fase 3: Notificaciones
- [ ] Crear `api/services/push_notification_service.py`
- [ ] Integrar envío de push en el flujo de generación de reporte
- [ ] Crear endpoint para registrar FCM tokens
- [ ] Flutter: registrar FCM token al login
- [ ] Flutter: manejar notificación de reporte diario
- [ ] Flutter: banner in-app de reporte no leído

### Fase 4: Flutter UI
- [ ] Crear `lib/backend/http/api/daily_reports.dart`
- [ ] Crear `lib/providers/daily_report_provider.dart`
- [ ] Crear `lib/pages/daily_report/daily_report_page.dart`
- [ ] Integrar en navegación (desde notificación + desde Insights)
- [ ] Localizar textos (en/es)

### Fase 5: Web Platform
- [ ] Crear página de dashboard con gráficas de tendencia
- [ ] Implementar vista de reporte diario detallado
- [ ] Implementar selector de período (semana/mes/año)
- [ ] Testing con datos reales

---

## Costo Estimado de Operación

### OpenAI (gpt-4o-mini)

| Concepto | Tokens Est. | Costo por Reporte |
|----------|-------------|-------------------|
| Input (conversaciones del día) | ~1500 | ~$0.000225 |
| Output (reporte JSON) | ~500 | ~$0.000075 |
| **Total por reporte** | | **~$0.0003** |

**Escala mensual**:
- 100 usuarios activos × 30 días = 3,000 reportes
- 3,000 × $0.0003 = **~$0.90/mes**

El costo es insignificante comparado con el valor proporcionado.

### Vercel Cron

- Hobby plan: 2 cron jobs gratis
- Pro plan: 40 cron jobs incluidos
- **Costo adicional: $0**

---

## Riesgos y Mitigaciones

| Riesgo | Impacto | Mitigación |
|--------|---------|------------|
| Cron no ejecuta | Alto | Endpoint manual + monitoreo + alertas |
| Timeout en usuarios con muchas conversaciones | Medio | Limitar a 50 conversaciones por día |
| Scores inconsistentes entre días | Medio | Prompt estructurado + temperatura baja |
| Push notification no llega | Bajo | Banner in-app como fallback |
| Muchos usuarios simultáneos | Medio | Procesamiento secuencial con delay entre usuarios |
| Tabla crece mucho | Bajo | 1 registro/usuario/día, política de retención opcional |

---

## Métricas de Éxito

1. **Cobertura**: ≥95% de días activos tienen reporte generado
2. **Entrega de notificaciones**: ≥80% de reportes generan push exitoso
3. **Engagement**: ≥50% de usuarios abren su reporte diario
4. **Consistencia de scores**: Desviación estándar ≤ 1.5 para el mismo patrón de comunicación
5. **Latencia del cron**: < 5 min para procesar 100 usuarios
