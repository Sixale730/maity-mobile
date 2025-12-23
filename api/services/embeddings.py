"""OpenAI embeddings service for semantic search"""
import os
from typing import List, Optional
import openai


# Model for embeddings - 1536 dimensions
EMBEDDING_MODEL = "text-embedding-3-small"


async def generate_embedding(text: str) -> Optional[List[float]]:
    """
    Generate embedding for a single text using OpenAI.

    Args:
        text: The text to embed

    Returns:
        List of floats (1536 dimensions) or None if failed
    """
    if not text or len(text.strip()) < 3:
        return None

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        # Limit text length for API
        max_chars = 8000
        if len(text) > max_chars:
            text = text[:max_chars]

        response = await client.embeddings.create(
            model=EMBEDDING_MODEL,
            input=text,
        )

        return response.data[0].embedding

    except Exception as e:
        print(f"[Embeddings] Error generating embedding: {e}")
        return None


async def generate_embeddings_batch(texts: List[str]) -> List[Optional[List[float]]]:
    """
    Generate embeddings for multiple texts in batch.

    Args:
        texts: List of texts to embed

    Returns:
        List of embeddings (or None for failed ones)
    """
    if not texts:
        return []

    try:
        client = openai.AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

        # Filter and limit texts
        max_chars = 8000
        processed_texts = []
        valid_indices = []

        for i, text in enumerate(texts):
            if text and len(text.strip()) >= 3:
                processed_texts.append(text[:max_chars] if len(text) > max_chars else text)
                valid_indices.append(i)

        if not processed_texts:
            return [None] * len(texts)

        response = await client.embeddings.create(
            model=EMBEDDING_MODEL,
            input=processed_texts,
        )

        # Map embeddings back to original indices
        result = [None] * len(texts)
        for j, embedding_data in enumerate(response.data):
            original_index = valid_indices[j]
            result[original_index] = embedding_data.embedding

        return result

    except Exception as e:
        print(f"[Embeddings] Error generating batch embeddings: {e}")
        return [None] * len(texts)
