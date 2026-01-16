"""Messages router - Chat with OpenAI (no persistence)"""
import json
from fastapi import APIRouter, Query
from fastapi.responses import StreamingResponse
from openai import AsyncOpenAI
import os

router = APIRouter(prefix="/v2", tags=["messages"])
client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))


@router.post("/messages")
async def send_message(text: str = Query(...), app_id: str = Query(None)):
    """Send message to OpenAI and stream response"""
    async def generate():
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": "Eres Maity, un asistente útil y amigable."},
                {"role": "user", "content": text}
            ],
            stream=True
        )
        async for chunk in response:
            if chunk.choices[0].delta.content:
                yield f"data: {json.dumps({'type': 'data', 'content': chunk.choices[0].delta.content})}\n\n"
        yield f"data: {json.dumps({'type': 'done'})}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@router.delete("/messages")
async def clear_messages():
    """Clear chat - no-op since no persistence"""
    return {"status": "ok"}
