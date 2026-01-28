"""Memory extraction service using OpenAI"""
import asyncio
import json
import os
from typing import List, Optional
from datetime import datetime
import openai

from ..models.memory import Memory, MemoryCategory
from .utils import parse_json_from_llm


# Initialize OpenAI client
openai.api_key = os.getenv("OPENAI_API_KEY")

EXTRACT_MEMORIES_PROMPT = """Analiza esta conversación y extrae 2-5 hechos o insights interesantes que el usuario querría recordar.

Un "hecho interesante" es:
- Información factual mencionada (fechas, nombres, lugares, decisiones importantes)
- Insights o aprendizajes compartidos durante la conversación
- Compromisos, promesas o acuerdos mencionados
- Datos específicos que el usuario querría recordar después (precios, direcciones, nombres)
- Recomendaciones recibidas o dadas

NO incluyas:
- Saludos o despedidas genéricas
- Información obvia o trivial
- Fragmentos sin contexto útil

RESPONDE ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{{
  "memories": [
    {{
      "content": "Hecho o insight específico en 1-2 oraciones claras"
    }}
  ]
}}

Si no hay hechos interesantes que valga la pena recordar, retorna: {{"memories": []}}

TRANSCRIPCIÓN:
{transcript}"""


async def extract_memories_from_transcript(
    transcript: str,
    conversation_id: Optional[str] = None,
) -> List[dict]:
    """
    Extract interesting memories from a conversation transcript.

    Args:
        transcript: Full conversation transcript text
        conversation_id: Optional ID of the source conversation

    Returns:
        List of memory dicts with content and category
    """
    if not transcript or len(transcript.strip()) < 50:
        print("[Memory Extractor] Transcript too short, skipping extraction")
        return []

    # Limit transcript length for API
    max_chars = 4000
    truncated = transcript[:max_chars] if len(transcript) > max_chars else transcript

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        # Add timeout to prevent indefinite blocking
        response = await asyncio.wait_for(
            client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {
                        "role": "system",
                        "content": "Eres un asistente que analiza conversaciones y extrae hechos e insights importantes para recordar. Responde SOLO con JSON válido, sin markdown ni explicaciones."
                    },
                    {
                        "role": "user",
                        "content": EXTRACT_MEMORIES_PROMPT.format(transcript=truncated)
                    }
                ],
                max_tokens=600,
                temperature=0.7,
            ),
            timeout=20.0  # 20 seconds max
        )

        content = response.choices[0].message.content
        if content:
            return _parse_memories_response(content, conversation_id)

    except asyncio.TimeoutError:
        print("[Memory Extractor] OpenAI timeout after 20s")
    except Exception as e:
        print(f"[Memory Extractor] OpenAI error: {e}")

    return []


def _parse_memories_response(
    content: str,
    conversation_id: Optional[str] = None,
) -> List[dict]:
    """Parse OpenAI JSON response into memory dicts"""
    try:
        data = parse_json_from_llm(content)
        memories = []

        for item in data.get("memories", []):
            content_text = item.get("content", "").strip()
            if content_text and len(content_text) >= 10:
                memories.append({
                    "content": content_text,
                    "category": MemoryCategory.INTERESTING.value,
                    "conversation_id": conversation_id,
                    "manually_added": False,
                    "reviewed": False,
                })

        print(f"[Memory Extractor] Extracted {len(memories)} memories")
        return memories

    except json.JSONDecodeError as e:
        print(f"[Memory Extractor] JSON parse error: {e}")
        return []


async def extract_memories_from_segments(
    segments: List[dict],
    conversation_id: Optional[str] = None,
) -> List[dict]:
    """
    Extract memories from transcript segments.

    Args:
        segments: List of segment dicts with 'text', 'is_user', 'speaker_id'
        conversation_id: Optional ID of the source conversation

    Returns:
        List of memory dicts
    """
    # Build transcript text from segments
    transcript_parts = []
    for s in segments:
        speaker = "Usuario" if s.get("is_user") else f"Hablante {s.get('speaker_id', 0)}"
        text = s.get("text", "")
        if text:
            transcript_parts.append(f"{speaker}: {text}")

    transcript = "\n".join(transcript_parts)
    return await extract_memories_from_transcript(transcript, conversation_id)
