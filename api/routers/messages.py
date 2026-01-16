"""Messages router - Chat with OpenAI (function calling for conversation access)"""
import json
import base64
from datetime import datetime, timedelta
from fastapi import APIRouter, Query, Depends
from fastapi.responses import StreamingResponse
from openai import AsyncOpenAI
from pydantic import BaseModel
from typing import Optional, List
import os

from ..services.supabase_client import (
    get_conversations,
    get_conversation_with_segments,
    search_conversations_by_embedding,
)
from ..services.embeddings import generate_embedding
from ..services.supabase_auth import optional_auth_user_id

router = APIRouter(prefix="/v2", tags=["messages"])
client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))


class MessageRequest(BaseModel):
    text: str
    file_ids: Optional[List[str]] = None
    messages: Optional[List[dict]] = None  # Message history for context


# System prompt for Maity
SYSTEM_PROMPT = """Eres Maity, un asistente personal inteligente y amigable.

Tienes acceso a las conversaciones grabadas del usuario a través de su wearable OMI.
Puedes buscar y consultar estas conversaciones para ayudar al usuario a recordar
lo que habló, encontrar información específica, o hacer resúmenes.

Cuando el usuario pregunte sobre sus conversaciones:
- Usa buscar_conversaciones para encontrar conversaciones por fecha
- Usa buscar_semantico para encontrar conversaciones por tema o contenido
- Usa obtener_conversacion para ver los detalles completos de una conversación

Responde siempre en español de manera natural y conversacional.
Si no encuentras información relevante, dilo amablemente.

Fecha actual: {current_date}
"""


# Tool definitions for OpenAI function calling
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "buscar_conversaciones",
            "description": "Busca conversaciones del usuario por rango de fechas. Útil para preguntas como '¿de qué hablé ayer?' o 'mis conversaciones de la semana pasada'",
            "parameters": {
                "type": "object",
                "properties": {
                    "fecha_inicio": {
                        "type": "string",
                        "description": "Fecha de inicio en formato YYYY-MM-DD. Por defecto es hace 7 días."
                    },
                    "fecha_fin": {
                        "type": "string",
                        "description": "Fecha de fin en formato YYYY-MM-DD. Por defecto es hoy."
                    },
                    "limite": {
                        "type": "integer",
                        "description": "Número máximo de conversaciones a retornar",
                        "default": 10
                    }
                }
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "obtener_conversacion",
            "description": "Obtiene el contenido completo de una conversación específica por su ID, incluyendo la transcripción completa",
            "parameters": {
                "type": "object",
                "properties": {
                    "conversation_id": {
                        "type": "string",
                        "description": "UUID de la conversación a obtener"
                    }
                },
                "required": ["conversation_id"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "buscar_semantico",
            "description": "Busca conversaciones usando búsqueda semántica. Útil para encontrar conversaciones sobre un tema específico, por ejemplo 'conversaciones sobre el proyecto X' o 'cuando hablé de vacaciones'",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Texto o tema a buscar en las conversaciones"
                    },
                    "limite": {
                        "type": "integer",
                        "description": "Número máximo de resultados",
                        "default": 5
                    }
                },
                "required": ["query"]
            }
        }
    }
]


async def buscar_conversaciones_db(user_id: str, fecha_inicio: str = None, fecha_fin: str = None, limite: int = 10) -> dict:
    """Busca conversaciones por rango de fechas"""
    try:
        # Default: last 7 days
        if not fecha_fin:
            fecha_fin = datetime.now().strftime("%Y-%m-%d")
        if not fecha_inicio:
            fecha_inicio = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")

        conversations = await get_conversations(
            user_id=user_id,
            limit=limite,
            include_discarded=False,
        )

        # Filter by date range
        filtered = []
        for conv in conversations:
            created = conv.get("created_at", "")[:10]  # Get YYYY-MM-DD
            if fecha_inicio <= created <= fecha_fin:
                filtered.append({
                    "id": conv.get("id"),
                    "title": conv.get("title"),
                    "overview": conv.get("overview"),
                    "emoji": conv.get("emoji"),
                    "category": conv.get("category"),
                    "created_at": conv.get("created_at"),
                    "duration_seconds": conv.get("duration_seconds"),
                    "words_count": conv.get("words_count"),
                })

        return {
            "conversaciones": filtered[:limite],
            "total": len(filtered),
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
        }
    except Exception as e:
        return {"error": str(e), "conversaciones": []}


async def obtener_conversacion_db(user_id: str, conversation_id: str) -> dict:
    """Obtiene una conversación con sus segmentos"""
    try:
        result = await get_conversation_with_segments(
            user_id=user_id,
            conversation_id=conversation_id,
        )

        if not result:
            return {"error": "Conversación no encontrada"}

        conv = result.get("conversation", {})
        segments = result.get("segments", [])

        # Build readable transcript
        transcript_lines = []
        for seg in segments:
            speaker = "Tú" if seg.get("is_user") else (seg.get("speaker") or "Otro")
            transcript_lines.append(f"{speaker}: {seg.get('text', '')}")

        return {
            "id": conv.get("id"),
            "title": conv.get("title"),
            "overview": conv.get("overview"),
            "emoji": conv.get("emoji"),
            "category": conv.get("category"),
            "created_at": conv.get("created_at"),
            "duration_seconds": conv.get("duration_seconds"),
            "transcripcion": "\n".join(transcript_lines),
            "action_items": conv.get("action_items", []),
        }
    except Exception as e:
        return {"error": str(e)}


async def buscar_semantico_db(user_id: str, query: str, limite: int = 5) -> dict:
    """Búsqueda semántica en conversaciones"""
    try:
        # Generate embedding for query
        query_embedding = await generate_embedding(query)

        if not query_embedding:
            return {"error": "No se pudo procesar la búsqueda", "resultados": []}

        results = await search_conversations_by_embedding(
            user_id=user_id,
            query_embedding=query_embedding,
            limit=limite,
            similarity_threshold=0.5,  # Lower threshold for chat
        )

        formatted = []
        for conv in results:
            formatted.append({
                "id": conv.get("id"),
                "title": conv.get("title"),
                "overview": conv.get("overview"),
                "emoji": conv.get("emoji"),
                "created_at": conv.get("created_at"),
                "relevancia": conv.get("similarity", 0),
            })

        return {
            "query": query,
            "resultados": formatted,
            "total": len(formatted),
        }
    except Exception as e:
        return {"error": str(e), "resultados": []}


async def ejecutar_tool(tool_name: str, args: dict, user_id: str) -> str:
    """Ejecuta una herramienta y retorna el resultado como JSON string"""

    if tool_name == "buscar_conversaciones":
        result = await buscar_conversaciones_db(
            user_id=user_id,
            fecha_inicio=args.get("fecha_inicio"),
            fecha_fin=args.get("fecha_fin"),
            limite=args.get("limite", 10),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "obtener_conversacion":
        result = await obtener_conversacion_db(
            user_id=user_id,
            conversation_id=args["conversation_id"],
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "buscar_semantico":
        result = await buscar_semantico_db(
            user_id=user_id,
            query=args["query"],
            limite=args.get("limite", 5),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    return json.dumps({"error": f"Herramienta '{tool_name}' no encontrada"})


@router.post("/messages")
async def send_message(
    request: MessageRequest,
    app_id: str = Query(None),
    user_id: str = Query(None, description="User ID (maity.users UUID) for conversation access"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Send message to OpenAI with function calling for conversation access"""

    async def generate():
        try:
            # Build system prompt with current date
            system_prompt = SYSTEM_PROMPT.format(
                current_date=datetime.now().strftime("%Y-%m-%d")
            )

            # Build messages array with system prompt
            messages = [{"role": "system", "content": system_prompt}]

            # Add message history if provided (for conversational context)
            if request.messages:
                for msg in request.messages:
                    role = msg.get("role", "user")
                    content = msg.get("content", "")
                    if role in ("user", "assistant") and content:
                        messages.append({"role": role, "content": content})

            # Add current user message
            messages.append({"role": "user", "content": request.text})

            # If no user_id, skip function calling and just respond
            if not user_id:
                response = await client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=messages,
                    stream=True,
                )

                full_response = ""
                async for chunk in response:
                    if chunk.choices[0].delta.content:
                        content = chunk.choices[0].delta.content
                        full_response += content
                        yield f"data: {content.replace(chr(10), '__CRLF__')}\n\n"

                # Send done
                message_obj = {
                    "id": "msg_1",
                    "text": full_response,
                    "created_at": None,
                    "sender": "ai",
                    "type": "text"
                }
                done_data = base64.b64encode(json.dumps(message_obj).encode()).decode()
                yield f"done: {done_data}\n\n"
                return

            # With user_id: Use function calling loop (max 5 iterations)
            for iteration in range(5):
                response = await client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=messages,
                    tools=TOOLS,
                    tool_choice="auto",
                    stream=False,  # No stream during tool calling
                )

                assistant_message = response.choices[0].message

                # Add assistant message to conversation
                messages.append({
                    "role": "assistant",
                    "content": assistant_message.content,
                    "tool_calls": [
                        {
                            "id": tc.id,
                            "type": "function",
                            "function": {
                                "name": tc.function.name,
                                "arguments": tc.function.arguments,
                            }
                        }
                        for tc in (assistant_message.tool_calls or [])
                    ] if assistant_message.tool_calls else None,
                })

                # If no tool calls, we have the final response
                if not assistant_message.tool_calls:
                    break

                # Execute each tool call
                for tool_call in assistant_message.tool_calls:
                    try:
                        args = json.loads(tool_call.function.arguments)
                    except json.JSONDecodeError:
                        args = {}

                    print(f"[Messages] Executing tool: {tool_call.function.name} with args: {args}")

                    result = await ejecutar_tool(
                        tool_name=tool_call.function.name,
                        args=args,
                        user_id=user_id,
                    )

                    messages.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "content": result,
                    })

            # Stream the final response
            final_response = await client.chat.completions.create(
                model="gpt-4o-mini",
                messages=messages,
                stream=True,
            )

            full_response = ""
            async for chunk in final_response:
                if chunk.choices[0].delta.content:
                    content = chunk.choices[0].delta.content
                    full_response += content
                    yield f"data: {content.replace(chr(10), '__CRLF__')}\n\n"

            # Send done with base64 encoded message object
            message_obj = {
                "id": "msg_1",
                "text": full_response,
                "created_at": None,
                "sender": "ai",
                "type": "text"
            }
            done_data = base64.b64encode(json.dumps(message_obj).encode()).decode()
            yield f"done: {done_data}\n\n"

        except Exception as e:
            print(f"[Messages] Error: {e}")
            # Send error message
            error_msg = "Lo siento, hubo un problema procesando tu mensaje. Por favor intenta de nuevo."
            yield f"data: {error_msg}\n\n"

            message_obj = {
                "id": "msg_error",
                "text": error_msg,
                "created_at": None,
                "sender": "ai",
                "type": "text"
            }
            done_data = base64.b64encode(json.dumps(message_obj).encode()).decode()
            yield f"done: {done_data}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@router.delete("/messages")
async def clear_messages(app_id: str = Query(None)):
    """Clear chat - no-op since no persistence"""
    return {"status": "ok"}
