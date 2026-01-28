"""Communication feedback analyzer service using OpenAI"""
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
)
from .utils import parse_json_from_llm


# Initialize OpenAI client
openai.api_key = os.getenv("OPENAI_API_KEY")

COMMUNICATION_ANALYSIS_PROMPT = """Analiza la comunicación del hablante principal (Usuario) en esta conversación y proporciona feedback constructivo.

TRANSCRIPCIÓN:
{transcript}

Genera feedback en español, enfocándote en:

1. FORTALEZAS (2-4 puntos): ¿Qué hace bien al comunicarse? Sé específico.
   - Ejemplos: claridad en sus mensajes, uso de ejemplos concretos, preguntas efectivas, manejo de objeciones, comunicación directa

2. ÁREAS DE MEJORA (2-4 puntos): ¿Qué podría mejorar? Da sugerencias concretas y constructivas.
   - Ejemplos: ser más conciso, estructurar mejor las ideas, incluir más llamados a acción, ofrecer alternativas al objetar

3. OBSERVACIONES por categoría (1-2 oraciones cada una):
   - Claridad: ¿Qué tan entendibles y directos son sus mensajes?
   - Estructura: ¿Cómo organiza sus ideas? ¿Hay secuencia lógica?
   - Llamados a acción: ¿Invita a tomar acciones específicas? ¿Usa frases como "hagamos", "deberíamos", "te propongo"?
   - Objeciones: ¿Cómo maneja los "peros", "sin embargo", "aunque"? ¿Ofrece alternativas?

4. RESUMEN: Una oración que capture el estilo de comunicación general del usuario.

5. CONTADORES (métricas cuantitativas):
   - pero_count: Número de veces que el Usuario dice "pero" (exactamente la palabra "pero")
   - objection_words: Frecuencia de palabras de objeción que usa el Usuario {{"pero": N, "sin embargo": N, "aunque": N, "no obstante": N}}
   - objections_received: Lista de objeciones/resistencias que el Otro le hace al Usuario (máx 5, frases cortas)
   - objections_made: Lista de objeciones que el Usuario hace (máx 5, frases cortas que empiecen con "pero", "sin embargo", etc.)
   - filler_words: Frecuencia de muletillas del Usuario {{"este": N, "o sea": N, "como que": N, "bueno": N, "entonces": N, "básicamente": N, "literalmente": N, "tipo": N, "digamos": N, "la verdad": N}}

IMPORTANTE:
- Sé constructivo y específico, no genérico
- Basa tu feedback en lo que realmente dice el Usuario en la transcripción
- Si la transcripción es muy corta, indica que necesitas más contexto
- Solo incluye muletillas y palabras de objeción que realmente aparezcan (no inventes)

Responde ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{{
  "strengths": ["fortaleza específica 1", "fortaleza específica 2"],
  "areas_to_improve": ["área de mejora específica 1", "área de mejora específica 2"],
  "observations": {{
    "clarity": "Observación sobre claridad...",
    "structure": "Observación sobre estructura...",
    "calls_to_action": "Observación sobre llamados a acción...",
    "objections": "Observación sobre manejo de objeciones..."
  }},
  "summary": "Resumen del estilo de comunicación en una oración.",
  "counters": {{
    "pero_count": 3,
    "objection_words": {{"pero": 3, "sin embargo": 1}},
    "objections_received": ["es muy caro", "no tenemos tiempo"],
    "objections_made": ["pero necesito más información", "sin embargo creo que..."],
    "filler_words": {{"este": 2, "o sea": 1, "bueno": 3}}
  }}
}}"""


async def analyze_communication(
    segments: List[TranscriptSegment],
) -> Optional[CommunicationFeedback]:
    """
    Analyze user's communication style from transcript segments.

    Args:
        segments: List of transcript segments

    Returns:
        CommunicationFeedback with strengths, areas to improve, observations
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
    max_chars = 4000
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
                        "content": "Eres un coach de comunicación que analiza conversaciones y proporciona feedback constructivo y específico. Responde SOLO con JSON válido, sin markdown ni explicaciones."
                    },
                    {
                        "role": "user",
                        "content": COMMUNICATION_ANALYSIS_PROMPT.format(transcript=transcript)
                    }
                ],
                max_tokens=800,
                temperature=0.7,
            ),
            timeout=20.0,
        )

        content = response.choices[0].message.content
        if content:
            return _parse_communication_response(content)

    except asyncio.TimeoutError:
        print("[Communication Analyzer] OpenAI timeout after 20s")
    except Exception as e:
        print(f"[Communication Analyzer] Error: {e}")

    return _generate_minimal_feedback()


def _parse_communication_response(content: str) -> CommunicationFeedback:
    """Parse OpenAI JSON response into CommunicationFeedback"""
    try:
        data = parse_json_from_llm(content)

        # Parse observations
        obs_data = data.get("observations", {})
        observations = CommunicationObservations(
            clarity=obs_data.get("clarity", ""),
            structure=obs_data.get("structure", ""),
            calls_to_action=obs_data.get("calls_to_action", ""),
            objections=obs_data.get("objections", ""),
        )

        # Parse counters
        counters_data = data.get("counters", {})
        counters = None
        if counters_data:
            counters = CommunicationCounters(
                pero_count=counters_data.get("pero_count", 0),
                objection_words=counters_data.get("objection_words", {}),
                objections_received=counters_data.get("objections_received", [])[:5],
                objections_made=counters_data.get("objections_made", [])[:5],
                filler_words=counters_data.get("filler_words", {}),
            )

        return CommunicationFeedback(
            strengths=data.get("strengths", [])[:5],  # Limit to 5
            areas_to_improve=data.get("areas_to_improve", [])[:5],
            observations=observations,
            summary=data.get("summary", "")[:300],
            counters=counters,
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
            clarity="No hay suficiente contenido para analizar la claridad.",
            structure="No hay suficiente contenido para analizar la estructura.",
            calls_to_action="No hay suficiente contenido para analizar los llamados a acción.",
            objections="No hay suficiente contenido para analizar el manejo de objeciones.",
        ),
        summary="Conversación muy breve para generar feedback detallado.",
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
