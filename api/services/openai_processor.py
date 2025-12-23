"""OpenAI conversation processor service"""
import json
import os
from datetime import datetime
from typing import List, Optional, Dict, Any
import openai
from ..models.conversation import (
    TranscriptSegment,
    StructuredData,
    ActionItem,
    Event,
    CategoryEnum,
)


# Initialize OpenAI client
openai.api_key = os.getenv("OPENAI_API_KEY")

PROCESS_CONVERSATION_PROMPT = """Analiza esta transcripción y extrae información estructurada.

CATEGORÍAS DISPONIBLES (elige UNA):
personal, education, health, finance, legal, philosophy, spiritual, science,
entrepreneurship, parenting, romantic, travel, inspiration, technology, business,
social, work, sports, politics, literature, history, architecture, music, weather,
news, entertainment, psychology, design, family, economics, environment, other

RESPONDE ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{
  "title": "Título corto descriptivo (max 50 chars)",
  "emoji": "Un emoji representativo",
  "overview": "Resumen de 2-3 oraciones capturando los puntos principales",
  "category": "categoria_de_la_lista",
  "action_items": [
    {"description": "Tarea específica a realizar", "due_at": "YYYY-MM-DD o null si no hay fecha"}
  ],
  "events": [
    {"title": "Nombre del evento", "start": "YYYY-MM-DDTHH:MM:SS", "duration_minutes": 30, "description": "Detalle opcional"}
  ]
}

NOTAS:
- El título debe capturar la esencia de la conversación
- El emoji debe representar el tema o tono principal
- action_items: tareas, pendientes, cosas por hacer mencionadas
- events: citas, reuniones, eventos con fecha/hora específica mencionados
- Si no hay action_items o events, devuelve arrays vacíos []

TRANSCRIPCIÓN:
{transcript}"""


async def process_conversation(
    segments: List[TranscriptSegment],
) -> StructuredData:
    """
    Process transcript segments with OpenAI to extract structured data.

    Args:
        segments: List of transcript segments

    Returns:
        StructuredData with title, emoji, overview, category, action_items, events
    """
    # Build transcript text
    transcript = "\n".join([
        f"{'Usuario' if s.is_user else f'Hablante {s.speaker_id or 0}'}: {s.text}"
        for s in segments
    ])

    if len(transcript) < 20:
        return _generate_fallback(transcript)

    # Limit transcript length for API
    max_chars = 3000
    if len(transcript) > max_chars:
        transcript = transcript[:max_chars] + "..."

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": "Eres un asistente que analiza conversaciones y extrae información estructurada. Responde SOLO con JSON válido, sin markdown ni explicaciones."
                },
                {
                    "role": "user",
                    "content": PROCESS_CONVERSATION_PROMPT.format(transcript=transcript)
                }
            ],
            max_tokens=500,
            temperature=0.7,
        )

        content = response.choices[0].message.content
        if content:
            return _parse_response(content)

    except Exception as e:
        print(f"[OpenAI Processor] Error: {e}")

    return _generate_fallback(transcript)


def _parse_response(content: str) -> StructuredData:
    """Parse OpenAI JSON response into StructuredData"""
    try:
        # Clean potential markdown
        json_str = content.strip()
        if json_str.startswith("```"):
            json_str = json_str.split("```")[1]
            if json_str.startswith("json"):
                json_str = json_str[4:]
            json_str = json_str.strip()

        data = json.loads(json_str)

        # Parse action items
        action_items = []
        for item in data.get("action_items", []):
            due_at = None
            if item.get("due_at"):
                try:
                    due_at = datetime.fromisoformat(item["due_at"].replace("Z", "+00:00"))
                except:
                    pass
            action_items.append(ActionItem(
                description=item.get("description", ""),
                due_at=due_at,
            ))

        # Parse events
        events = []
        for event in data.get("events", []):
            try:
                start = datetime.fromisoformat(event["start"].replace("Z", "+00:00"))
                events.append(Event(
                    title=event.get("title", "Evento"),
                    start=start,
                    duration_minutes=event.get("duration_minutes", 30),
                    description=event.get("description"),
                ))
            except:
                pass

        # Parse category
        category_str = data.get("category", "other").lower()
        try:
            category = CategoryEnum(category_str)
        except ValueError:
            category = CategoryEnum.OTHER

        return StructuredData(
            title=data.get("title", "Conversación")[:60],
            emoji=data.get("emoji", "🎤"),
            overview=data.get("overview", "")[:500],
            category=category,
            action_items=action_items,
            events=events,
        )

    except json.JSONDecodeError as e:
        print(f"[OpenAI Processor] JSON parse error: {e}")
        return _generate_fallback("")


def _generate_fallback(transcript: str) -> StructuredData:
    """Generate fallback structured data when OpenAI fails"""
    # Extract first words as title
    words = transcript.split()[:8]
    title = " ".join(words)
    if len(title) > 50:
        title = title[:47] + "..."

    # Determine emoji based on keywords
    emoji = "🎤"
    lower = transcript.lower()

    keyword_emojis = {
        ("trabajo", "reunión", "proyecto", "oficina"): "💼",
        ("comida", "comer", "restaurante", "almuerzo"): "🍽️",
        ("viaje", "vacaciones", "viajar", "vuelo"): "✈️",
        ("música", "canción", "concierto"): "🎵",
        ("deporte", "ejercicio", "gym", "correr"): "🏃",
        ("familia", "hijo", "mamá", "papá"): "👨‍👩‍👧",
        ("amor", "romántic", "cita", "pareja"): "❤️",
        ("estudio", "examen", "clase", "universidad"): "📚",
        ("salud", "médico", "doctor", "hospital"): "🏥",
        ("dinero", "compra", "precio", "pagar"): "💰",
        ("tecnología", "app", "software", "código"): "💻",
    }

    for keywords, em in keyword_emojis.items():
        if any(kw in lower for kw in keywords):
            emoji = em
            break

    # Determine category
    category = CategoryEnum.OTHER
    category_keywords = {
        CategoryEnum.WORK: ["trabajo", "reunión", "proyecto", "oficina", "jefe"],
        CategoryEnum.HEALTH: ["médico", "doctor", "salud", "hospital", "enfermo"],
        CategoryEnum.EDUCATION: ["estudio", "examen", "clase", "profesor", "universidad"],
        CategoryEnum.FAMILY: ["familia", "hijo", "mamá", "papá", "hermano"],
        CategoryEnum.TRAVEL: ["viaje", "vacaciones", "vuelo", "hotel"],
        CategoryEnum.FINANCE: ["dinero", "banco", "pagar", "precio", "cuenta"],
        CategoryEnum.TECHNOLOGY: ["app", "software", "código", "computadora"],
        CategoryEnum.ENTERTAINMENT: ["película", "serie", "juego", "música"],
    }

    for cat, keywords in category_keywords.items():
        if any(kw in lower for kw in keywords):
            category = cat
            break

    return StructuredData(
        title=title if title else "Conversación",
        emoji=emoji,
        overview=transcript[:300] if transcript else "",
        category=category,
        action_items=[],
        events=[],
    )


def count_words(segments: List[TranscriptSegment]) -> int:
    """Count total words in transcript segments"""
    return sum(len(s.text.split()) for s in segments)


def calculate_duration(segments: List[TranscriptSegment]) -> int:
    """Calculate duration in seconds from segments"""
    if not segments:
        return 0

    # If segments have timing info
    if segments[-1].end > 0:
        return int(segments[-1].end - segments[0].start)

    # Estimate: ~150 words per minute
    words = count_words(segments)
    return int(words / 150 * 60)


def count_insights(structured: StructuredData) -> int:
    """Count insights (action items + events)"""
    return len(structured.action_items) + len(structured.events)
