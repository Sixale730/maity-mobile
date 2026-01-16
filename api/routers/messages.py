"""Messages router - Chat with OpenAI (no persistence)"""
import json
import base64
from fastapi import APIRouter, Query
from fastapi.responses import StreamingResponse
from openai import AsyncOpenAI
from pydantic import BaseModel
from typing import Optional, List
import os

router = APIRouter(prefix="/v2", tags=["messages"])
client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))


class MessageRequest(BaseModel):
    text: str
    file_ids: Optional[List[str]] = None


@router.post("/messages")
async def send_message(request: MessageRequest, app_id: str = Query(None)):
    """Send message to OpenAI and stream response"""

    async def generate():
        full_response = ""
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": "Eres Maity, un asistente útil y amigable."},
                {"role": "user", "content": request.text}
            ],
            stream=True
        )

        async for chunk in response:
            if chunk.choices[0].delta.content:
                content = chunk.choices[0].delta.content
                full_response += content
                # Format: "data: <content>\n" (Flutter expects this)
                yield f"data: {content.replace(chr(10), '__CRLF__')}\n"

        # Send done with base64 encoded message object
        message_obj = {
            "id": "msg_1",
            "text": full_response,
            "created_at": None,
            "sender": "ai",
            "type": "text"
        }
        done_data = base64.b64encode(json.dumps(message_obj).encode()).decode()
        yield f"done: {done_data}\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@router.delete("/messages")
async def clear_messages(app_id: str = Query(None)):
    """Clear chat - no-op since no persistence"""
    return {"status": "ok"}
