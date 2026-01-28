"""Chunked processor for long transcripts.

Splits transcripts >6000 chars into sentence-boundary chunks,
processes each with OpenAI, then merges results into a single
structured output.
"""
import asyncio
import os
import re
from typing import List, Dict, Optional

import openai

from .utils import parse_json_from_llm


CHUNK_PROCESS_PROMPT = """Analiza este fragmento de conversación y extrae información estructurada.

CATEGORÍAS DISPONIBLES (elige UNA):
personal, education, health, finance, legal, philosophy, spiritual, science,
entrepreneurship, parenting, romantic, travel, inspiration, technology, business,
social, work, sports, politics, literature, history, architecture, music, weather,
news, entertainment, psychology, design, family, economics, environment, other

Responde ÚNICAMENTE en formato JSON:
{{
  "partial_summary": "Resumen de este fragmento en 2-3 oraciones",
  "category": "categoria_de_la_lista",
  "action_items": [
    {{"description": "Tarea específica mencionada"}}
  ],
  "events": [],
  "discarded": false,
  "key_topics": ["tema1", "tema2"]
}}

FRAGMENTO {chunk_number} de {total_chunks}:
{chunk_text}"""


MERGE_PROMPT = """Tienes los resúmenes parciales de una conversación larga que fue dividida en fragmentos.
Combínalos en un único análisis coherente.

CATEGORÍAS DISPONIBLES (elige UNA):
personal, education, health, finance, legal, philosophy, spiritual, science,
entrepreneurship, parenting, romantic, travel, inspiration, technology, business,
social, work, sports, politics, literature, history, architecture, music, weather,
news, entertainment, psychology, design, family, economics, environment, other

IMPORTANTE - Marca "discarded": true SOLO si TODOS los fragmentos son irrelevantes.

Responde ÚNICAMENTE en formato JSON:
{{
  "title": "Título corto (max 50 chars) que cubra toda la conversación",
  "emoji": "Un emoji representativo",
  "overview": "Resumen completo de 3-5 oraciones cubriendo TODOS los fragmentos",
  "category": "categoria_de_la_lista",
  "action_items": [
    {{"description": "Tarea específica mencionada"}}
  ],
  "events": [],
  "discarded": false
}}

RESÚMENES PARCIALES:
{partial_summaries}"""


def split_at_sentence_boundaries(text: str, max_chars: int = 5000) -> List[str]:
    """Split text at sentence boundaries, respecting max_chars per chunk."""
    if len(text) <= max_chars:
        return [text]

    # Split into sentences (handles Spanish punctuation)
    sentences = re.split(r'(?<=[.!?¿¡])\s+', text)

    chunks = []
    current_chunk = ""

    for sentence in sentences:
        # If a single sentence exceeds max_chars, split it at word boundaries
        if len(sentence) > max_chars:
            if current_chunk:
                chunks.append(current_chunk.strip())
                current_chunk = ""

            words = sentence.split()
            sub_chunk = ""
            for word in words:
                if len(sub_chunk) + len(word) + 1 > max_chars:
                    chunks.append(sub_chunk.strip())
                    sub_chunk = word
                else:
                    sub_chunk = f"{sub_chunk} {word}" if sub_chunk else word
            if sub_chunk:
                current_chunk = sub_chunk
            continue

        if len(current_chunk) + len(sentence) + 1 > max_chars:
            chunks.append(current_chunk.strip())
            current_chunk = sentence
        else:
            current_chunk = f"{current_chunk} {sentence}" if current_chunk else sentence

    if current_chunk.strip():
        chunks.append(current_chunk.strip())

    return chunks


async def _process_chunk(
    chunk_text: str,
    chunk_number: int,
    total_chunks: int,
    client: openai.AsyncOpenAI,
) -> Optional[Dict]:
    """Process a single chunk with OpenAI."""
    try:
        response = await asyncio.wait_for(
            client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {
                        "role": "system",
                        "content": "Eres un asistente que analiza fragmentos de conversaciones. Responde SOLO con JSON válido."
                    },
                    {
                        "role": "user",
                        "content": CHUNK_PROCESS_PROMPT.format(
                            chunk_number=chunk_number,
                            total_chunks=total_chunks,
                            chunk_text=chunk_text,
                        )
                    }
                ],
                max_tokens=500,
                temperature=0.7,
            ),
            timeout=30.0,
        )

        content = response.choices[0].message.content
        if content:
            return parse_json_from_llm(content)

    except asyncio.TimeoutError:
        print(f"[ChunkedProcessor] Chunk {chunk_number} timed out")
    except Exception as e:
        print(f"[ChunkedProcessor] Error processing chunk {chunk_number}: {e}")

    return None


async def _merge_results(
    partial_results: List[Dict],
    client: openai.AsyncOpenAI,
) -> Optional[Dict]:
    """Merge partial results from all chunks into a single structured output."""
    # Build summaries text
    summaries = []
    all_action_items = []
    all_events = []

    for i, result in enumerate(partial_results):
        if result is None:
            continue

        summary = result.get("partial_summary", "")
        topics = result.get("key_topics", [])
        summaries.append(f"Fragmento {i+1}: {summary} (Temas: {', '.join(topics)})")

        for item in result.get("action_items", []):
            if isinstance(item, dict) and item.get("description"):
                all_action_items.append(item)
            elif isinstance(item, str) and item:
                all_action_items.append({"description": item})

        all_events.extend(result.get("events", []))

    if not summaries:
        return None

    partial_summaries_text = "\n".join(summaries)

    # Include collected action items in the merge prompt
    action_items_note = ""
    if all_action_items:
        items_text = "\n".join([f"- {a['description']}" for a in all_action_items])
        action_items_note = f"\n\nACTION ITEMS encontrados en los fragmentos:\n{items_text}"

    try:
        response = await asyncio.wait_for(
            client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {
                        "role": "system",
                        "content": "Eres un asistente que combina resúmenes parciales en un análisis coherente. Responde SOLO con JSON válido."
                    },
                    {
                        "role": "user",
                        "content": MERGE_PROMPT.format(
                            partial_summaries=partial_summaries_text + action_items_note
                        )
                    }
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
        print("[ChunkedProcessor] Merge timed out")
    except Exception as e:
        print(f"[ChunkedProcessor] Error merging results: {e}")

    return None


async def process_long_transcript(
    transcript: str,
    model: str = "gpt-4o-mini",
) -> Optional[Dict]:
    """
    Process a long transcript by splitting into chunks, processing each,
    and merging results.

    For transcripts >6000 chars: divide, process per chunk, merge.

    Args:
        transcript: Full transcript text
        model: OpenAI model to use

    Returns:
        Structured dict with title, overview, emoji, category, action_items, events, discarded
    """
    if not transcript or len(transcript.strip()) < 50:
        return None

    client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

    chunks = split_at_sentence_boundaries(transcript, max_chars=5000)
    total_chunks = len(chunks)

    print(f"[ChunkedProcessor] Processing {total_chunks} chunks ({len(transcript)} chars total)")

    # Process chunks concurrently (max 3 at a time to avoid rate limits)
    semaphore = asyncio.Semaphore(3)

    async def process_with_semaphore(chunk, num, total):
        async with semaphore:
            return await _process_chunk(chunk, num, total, client)

    tasks = [
        process_with_semaphore(chunk, i + 1, total_chunks)
        for i, chunk in enumerate(chunks)
    ]

    partial_results = await asyncio.gather(*tasks)

    # Filter out None results
    valid_results = [r for r in partial_results if r is not None]

    if not valid_results:
        print("[ChunkedProcessor] All chunks failed, returning None")
        return None

    # If only one chunk succeeded, use it directly with some formatting
    if len(valid_results) == 1:
        result = valid_results[0]
        # Use partial_summary truncated as title (more descriptive than key_topics)
        summary = result.get("partial_summary", "Conversation")
        title = summary[:50].rsplit(' ', 1)[0] if len(summary) > 50 else summary
        return {
            "title": title or "Conversation",
            "overview": summary,
            "emoji": "🎤",
            "category": result.get("category", "other"),
            "action_items": result.get("action_items", []),
            "events": result.get("events", []),
            "discarded": result.get("discarded", False),
        }

    # Merge all partial results
    merged = await _merge_results(valid_results, client)

    if merged:
        print(f"[ChunkedProcessor] Successfully merged: {merged.get('title', 'N/A')}")

    return merged
