"""Communication feedback analyzer service using OpenAI - 6 competency standard"""
import asyncio
import json
import os
from typing import List, Optional
import openai
from ..models.conversation import TranscriptSegment
from ..models.communication import (
    CommunicationFeedback,
    CommunicationObservations,
    CommunicationCounters,
    Radiografia,
    Preguntas,
    AccionUsuario,
    TemaSinCerrar,
    Temas,
    Patron,
    CommunicationInsight,
)
from .utils import parse_json_from_llm


# Initialize OpenAI client
openai.api_key = os.getenv("OPENAI_API_KEY")

COMMUNICATION_ANALYSIS_PROMPT = """Eres un coach de comunicación experto. Evalúa la comunicación del hablante principal (Usuario) en esta conversación según las 6 competencias estándar.

TRANSCRIPCIÓN:
{transcript}

Evalúa cada competencia de 0 a 10 (un decimal):
1. **Claridad** (clarity): ¿Sus mensajes son directos, concretos y fáciles de entender?
2. **Estructura** (structure): ¿Organiza sus ideas con secuencia lógica, introduce-desarrolla-concluye?
3. **Vocabulario** (vocabulario): ¿Usa palabras precisas, variadas y apropiadas al contexto?
4. **Empatía** (empatia): ¿Escucha activamente, valida al otro, adapta su tono a la emoción del interlocutor?
5. **Objetivo** (objetivo): ¿Tiene un propósito claro en la conversación y lo persigue?
6. **Adaptación** (adaptacion): ¿Ajusta su estilo según el contexto, audiencia o cambios en la conversación?

overall_score = promedio simple de las 6 competencias.

Genera también:
- **radiografia**: muletillas detectadas con conteos, frecuencia, ratio habla usuario vs otros, conteos de palabras
- **preguntas**: preguntas textuales del usuario y del otro, con conteos
- **temas**: temas tratados, compromisos del usuario (con tiene_fecha), temas sin cerrar
- **patron**: patrón actual de comunicación, evolución durante la conversación, 3 señales clave, qué cambiaría
- **insights**: hasta 3 observaciones tipo "dato + por_qué + sugerencia" que el usuario quizás no notó
- **feedback**: texto breve general (1-2 oraciones)
- **strengths**: 2-4 fortalezas específicas
- **areas_to_improve**: 2-4 áreas de mejora con sugerencias concretas

Muletillas a detectar: "este", "o sea", "como que", "bueno", "entonces", "básicamente", "literalmente", "tipo", "digamos", "la verdad".

IMPORTANTE:
- Sé constructivo y específico, no genérico
- Basa tu feedback en lo que realmente dice el Usuario
- Solo incluye muletillas y conteos que realmente aparezcan
- Si la transcripción es muy corta, ajusta las secciones disponibles

Responde ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{{
  "overall_score": 7.2,
  "clarity": 7.5,
  "structure": 6.8,
  "vocabulario": 7.0,
  "empatia": 7.5,
  "objetivo": 7.0,
  "adaptacion": 7.5,
  "feedback": "Comunicación clara y directa, con oportunidad de mejorar la estructura.",
  "strengths": ["fortaleza 1", "fortaleza 2"],
  "areas_to_improve": ["área 1", "área 2"],
  "radiografia": {{
    "muletillas_detectadas": {{"este": 2, "bueno": 3}},
    "muletillas_total": 5,
    "muletillas_frecuencia": "1 cada 45 palabras",
    "ratio_habla": "65% usuario / 35% otros",
    "palabras_usuario": 230,
    "palabras_otros": 120
  }},
  "preguntas": {{
    "preguntas_usuario": ["¿Cuándo empezamos?", "¿Tienes el presupuesto?"],
    "preguntas_otros": ["¿Podrías explicar más?"],
    "total_usuario": 2,
    "total_otros": 1
  }},
  "temas": {{
    "temas_tratados": ["presupuesto Q1", "nueva estrategia"],
    "acciones_usuario": [
      {{"descripcion": "Enviar propuesta el lunes", "tiene_fecha": true}},
      {{"descripcion": "Revisar números con equipo", "tiene_fecha": false}}
    ],
    "temas_sin_cerrar": [
      {{"tema": "Timeline de implementación", "razon": "Se mencionó pero no se definió fecha"}}
    ]
  }},
  "patron": {{
    "actual": "Comunicador directo con tendencia a dominar la conversación",
    "evolucion": "Empezó conciso, se volvió más disperso al final",
    "senales": ["Usa preguntas cerradas", "No pausa para escuchar", "Repite puntos clave"],
    "que_cambiaria": "Incorporar más preguntas abiertas y pausas de escucha activa"
  }},
  "insights": [
    {{
      "dato": "El 70% de tus preguntas son cerradas (sí/no)",
      "por_que": "Limita la profundidad de las respuestas del otro",
      "sugerencia": "Prueba con '¿Qué opinas sobre...?' en lugar de '¿Estás de acuerdo?'"
    }}
  ]
}}"""


async def analyze_communication(
    segments: List[TranscriptSegment],
) -> Optional[CommunicationFeedback]:
    """
    Analyze user's communication style from transcript segments.

    Args:
        segments: List of transcript segments

    Returns:
        CommunicationFeedback with 6 competency scores + rich analysis
    """
    # Filter only user segments for analysis
    user_segments = [s for s in segments if s.is_user]

    # Si no hay segmentos del usuario, asumir que todos son del usuario
    # (conversación de una sola persona grabando)
    if not user_segments:
        user_segments = segments

    if not user_segments:
        # No segments at all to analyze
        return None

    # Build transcript text showing context
    transcript = "\n".join([
        f"{'Usuario' if s.is_user else f'Otro'}: {s.text}"
        for s in segments
    ])

    # Need minimum content to analyze
    total_user_words = sum(len(s.text.split()) for s in user_segments)
    if total_user_words < 15:
        return _generate_minimal_feedback()

    # Limit transcript length for API
    max_chars = 6000
    if len(transcript) > max_chars:
        transcript = transcript[:max_chars] + "..."

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        response = await asyncio.wait_for(
            client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {
                        "role": "system",
                        "content": "Eres un coach de comunicación experto que evalúa conversaciones con 6 competencias estándar y genera análisis rico. Responde SOLO con JSON válido, sin markdown ni explicaciones."
                    },
                    {
                        "role": "user",
                        "content": COMMUNICATION_ANALYSIS_PROMPT.format(transcript=transcript)
                    }
                ],
                max_tokens=2000,
                temperature=0.7,
            ),
            timeout=25.0,
        )

        content = response.choices[0].message.content
        if content:
            return _parse_communication_response(content)

    except asyncio.TimeoutError:
        print("[Communication Analyzer] OpenAI timeout after 25s")
    except Exception as e:
        print(f"[Communication Analyzer] Error: {e}")

    return _generate_minimal_feedback()


def _parse_communication_response(content: str) -> CommunicationFeedback:
    """Parse OpenAI JSON response into CommunicationFeedback with 6 competencies"""
    try:
        data = parse_json_from_llm(content)

        # Parse legacy observations (for backward compat in aggregation)
        observations = CommunicationObservations(
            clarity=data.get("feedback", ""),
            structure="",
            calls_to_action="",
            objections="",
        )

        # Parse radiografia
        radiografia = None
        rad_data = data.get("radiografia")
        if rad_data and isinstance(rad_data, dict):
            radiografia = Radiografia(
                muletillas_detectadas=rad_data.get("muletillas_detectadas", {}),
                muletillas_total=rad_data.get("muletillas_total", 0),
                muletillas_frecuencia=rad_data.get("muletillas_frecuencia", ""),
                ratio_habla=rad_data.get("ratio_habla", ""),
                palabras_usuario=rad_data.get("palabras_usuario", 0),
                palabras_otros=rad_data.get("palabras_otros", 0),
            )

            # Build counters from radiografia for backward compat
            counters = CommunicationCounters(
                pero_count=rad_data.get("muletillas_detectadas", {}).get("pero", 0),
                filler_words=rad_data.get("muletillas_detectadas", {}),
            )
        else:
            counters = None

        # Parse preguntas
        preguntas = None
        preg_data = data.get("preguntas")
        if preg_data and isinstance(preg_data, dict):
            preguntas = Preguntas(
                preguntas_usuario=preg_data.get("preguntas_usuario", [])[:10],
                preguntas_otros=preg_data.get("preguntas_otros", [])[:10],
                total_usuario=preg_data.get("total_usuario", 0),
                total_otros=preg_data.get("total_otros", 0),
            )

        # Parse temas
        temas = None
        temas_data = data.get("temas")
        if temas_data and isinstance(temas_data, dict):
            acciones = []
            for a in temas_data.get("acciones_usuario", [])[:10]:
                if isinstance(a, dict):
                    acciones.append(AccionUsuario(
                        descripcion=a.get("descripcion", ""),
                        tiene_fecha=a.get("tiene_fecha", False),
                    ))

            sin_cerrar = []
            for t in temas_data.get("temas_sin_cerrar", [])[:5]:
                if isinstance(t, dict):
                    sin_cerrar.append(TemaSinCerrar(
                        tema=t.get("tema", ""),
                        razon=t.get("razon", ""),
                    ))

            temas = Temas(
                temas_tratados=temas_data.get("temas_tratados", [])[:10],
                acciones_usuario=acciones,
                temas_sin_cerrar=sin_cerrar,
            )

        # Parse patron
        patron = None
        patron_data = data.get("patron")
        if patron_data and isinstance(patron_data, dict):
            patron = Patron(
                actual=patron_data.get("actual", ""),
                evolucion=patron_data.get("evolucion", ""),
                senales=patron_data.get("senales", [])[:5],
                que_cambiaria=patron_data.get("que_cambiaria", ""),
            )

        # Parse insights
        insights = []
        insights_data = data.get("insights", [])
        if isinstance(insights_data, list):
            for ins in insights_data[:3]:
                if isinstance(ins, dict):
                    insights.append(CommunicationInsight(
                        dato=ins.get("dato", ""),
                        por_que=ins.get("por_que", ""),
                        sugerencia=ins.get("sugerencia", ""),
                    ))

        return CommunicationFeedback(
            strengths=data.get("strengths", [])[:5],
            areas_to_improve=data.get("areas_to_improve", [])[:5],
            observations=observations,
            summary=data.get("feedback", "")[:300],
            counters=counters,
            # 6 competency scores
            overall_score=float(data.get("overall_score", 0)),
            clarity=float(data.get("clarity", 0)),
            structure=float(data.get("structure", 0)),
            vocabulario=float(data.get("vocabulario", 0)),
            empatia=float(data.get("empatia", 0)),
            objetivo=float(data.get("objetivo", 0)),
            adaptacion=float(data.get("adaptacion", 0)),
            # Rich analysis
            feedback=data.get("feedback", "")[:500],
            radiografia=radiografia,
            preguntas=preguntas,
            temas=temas,
            patron=patron,
            insights=insights,
        )

    except json.JSONDecodeError as e:
        print(f"[Communication Analyzer] JSON parse error: {e}")
        return _generate_minimal_feedback()


def _generate_minimal_feedback() -> CommunicationFeedback:
    """Generate minimal feedback when analysis cannot be performed"""
    return CommunicationFeedback(
        strengths=[],
        areas_to_improve=[],
        observations=CommunicationObservations(
            clarity="No hay suficiente contenido para analizar.",
            structure="",
            calls_to_action="",
            objections="",
        ),
        summary="Conversación muy breve para generar feedback detallado.",
        feedback="Conversación muy breve para generar feedback detallado.",
    )


def aggregate_feedback(
    feedback_list: List[CommunicationFeedback],
) -> dict:
    """
    Aggregate multiple CommunicationFeedback into summary statistics.

    Args:
        feedback_list: List of CommunicationFeedback from multiple conversations

    Returns:
        Dictionary with aggregated top strengths, areas to improve, and counts
    """
    if not feedback_list:
        return {
            "top_strengths": [],
            "top_areas_to_improve": [],
            "conversations_analyzed": 0,
        }

    # Count frequency of each strength and area
    strength_counts = {}
    area_counts = {}

    for fb in feedback_list:
        for s in fb.strengths:
            # Normalize similar strings
            key = s.lower().strip()
            if len(key) > 10:  # Only count meaningful feedback
                strength_counts[s] = strength_counts.get(s, 0) + 1

        for a in fb.areas_to_improve:
            key = a.lower().strip()
            if len(key) > 10:
                area_counts[a] = area_counts.get(a, 0) + 1

    # Sort by frequency and get top items
    top_strengths = sorted(strength_counts.items(), key=lambda x: -x[1])[:5]
    top_areas = sorted(area_counts.items(), key=lambda x: -x[1])[:5]

    return {
        "top_strengths": [s[0] for s in top_strengths],
        "top_areas_to_improve": [a[0] for a in top_areas],
        "conversations_analyzed": len(feedback_list),
    }
