"""Shared utility functions for backend services."""
import json


def parse_json_from_llm(content: str) -> dict:
    """Parse JSON from LLM response, handling markdown code blocks.

    LLMs sometimes wrap JSON in ```json ... ``` blocks despite being
    told not to. This function strips that wrapper before parsing.

    Args:
        content: Raw string from LLM response

    Returns:
        Parsed dict

    Raises:
        json.JSONDecodeError: If the content is not valid JSON
    """
    text = content.strip()
    if text.startswith("```"):
        parts = text.split("```")
        if len(parts) >= 3:
            text = parts[1]
        else:
            text = parts[1] if len(parts) > 1 else text
        if text.startswith("json"):
            text = text[4:]
        text = text.strip()
    return json.loads(text)
