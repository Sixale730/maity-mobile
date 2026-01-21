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
    get_day_summary,
    get_action_items,
    search_by_category,
    get_communication_feedback_aggregate,
    get_user_metrics,
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
SYSTEM_PROMPT = """Eres Maity, el asistente personal conectado al wearable OMI del usuario.

CAPACIDADES:
- Buscar y resumir conversaciones grabadas
- Generar resúmenes diarios con métricas (duración, palabras, categorías)
- Listar y buscar tareas pendientes (action items)
- Filtrar conversaciones por categoría
- Mostrar estadísticas de uso (diario, semanal, mensual)
- Analizar patrones de comunicación del usuario

HERRAMIENTAS DISPONIBLES:
1. buscar_conversaciones - Buscar por rango de fechas
2. obtener_conversacion - Ver detalles completos con transcripción
3. buscar_semantico - Búsqueda por tema o contenido
4. resumen_dia - Resumen completo del día con métricas
5. obtener_action_items - Lista de tareas pendientes
6. buscar_por_categoria - Filtrar por categoría específica
7. estadisticas_uso - Métricas de uso por período
8. feedback_comunicacion - Análisis del estilo de comunicación

CATEGORÍAS VÁLIDAS:
personal, work, education, health, finance, social, entertainment, travel,
food, shopping, technology, sports, news, music, art, science, politics,
religion, philosophy, history, geography, language, literature, math

REGLAS:
- Responde en español de manera natural y conversacional
- Sé conciso pero informativo
- Incluye emoji + título al mostrar conversaciones
- Usa formato claro para estadísticas y listas
- Para preguntas sobre "hoy", usa resumen_dia
- Para "mis tareas" o "pendientes", usa obtener_action_items
- Para "estadísticas" o "uso", usa estadisticas_uso

MANEJO DE RESULTADOS (MUY IMPORTANTE):
- Si una herramienta devuelve "total": 0 o listas vacías, INFORMA CLARAMENTE al usuario: "No encontré conversaciones en ese período" o similar
- Si hay un campo "error" en el resultado, informa: "Hubo un problema: [descripción]"
- NUNCA preguntes "¿Te gustaría saber más?" si NO mostraste información primero
- SIEMPRE muestra los datos encontrados ANTES de ofrecer opciones adicionales
- Si el resultado tiene campo "message", inclúyelo en tu respuesta

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
    },
    {
        "type": "function",
        "function": {
            "name": "resumen_dia",
            "description": "Obtiene un resumen completo del día con todas las conversaciones, métricas agregadas (duración total, palabras), categorías, action items pendientes y eventos. Útil para preguntas como '¿qué hice hoy?' o 'resumen de ayer'",
            "parameters": {
                "type": "object",
                "properties": {
                    "fecha": {
                        "type": "string",
                        "description": "Fecha en formato YYYY-MM-DD. Por defecto es hoy."
                    }
                }
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "obtener_action_items",
            "description": "Lista los action items (tareas pendientes) de las conversaciones del usuario. Útil para preguntas como 'mis pendientes', '¿qué tengo que hacer?' o 'tareas de la semana'",
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
                    "texto_busqueda": {
                        "type": "string",
                        "description": "Texto opcional para filtrar action items que contengan esta palabra"
                    },
                    "limite": {
                        "type": "integer",
                        "description": "Número máximo de action items a retornar",
                        "default": 20
                    }
                }
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "buscar_por_categoria",
            "description": "Busca conversaciones por categoría específica. Categorías: personal, work, education, health, finance, social, entertainment, travel, food, shopping, technology, sports, news, music, art, science",
            "parameters": {
                "type": "object",
                "properties": {
                    "categoria": {
                        "type": "string",
                        "description": "Categoría a buscar (ej: 'work', 'personal', 'health')"
                    },
                    "fecha_inicio": {
                        "type": "string",
                        "description": "Fecha de inicio en formato YYYY-MM-DD"
                    },
                    "fecha_fin": {
                        "type": "string",
                        "description": "Fecha de fin en formato YYYY-MM-DD"
                    },
                    "limite": {
                        "type": "integer",
                        "description": "Número máximo de conversaciones",
                        "default": 10
                    }
                },
                "required": ["categoria"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "estadisticas_uso",
            "description": "Obtiene estadísticas de uso del wearable. Muestra conversaciones, duración total, palabras transcritas, categorías top con porcentajes e historial diario. Útil para '¿cuánto he usado el wearable?', 'mis estadísticas del mes'",
            "parameters": {
                "type": "object",
                "properties": {
                    "periodo": {
                        "type": "string",
                        "enum": ["today", "weekly", "monthly", "yearly", "all"],
                        "description": "Período de las estadísticas: today, weekly, monthly, yearly, all",
                        "default": "monthly"
                    }
                }
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "feedback_comunicacion",
            "description": "Analiza el estilo de comunicación del usuario basado en el feedback de múltiples conversaciones. Muestra fortalezas, áreas de mejora, muletillas frecuentes y objeciones. Útil para '¿cómo me comunico?', 'análisis de mi comunicación'",
            "parameters": {
                "type": "object",
                "properties": {
                    "fecha_inicio": {
                        "type": "string",
                        "description": "Fecha de inicio en formato YYYY-MM-DD. Por defecto es hace 30 días."
                    },
                    "fecha_fin": {
                        "type": "string",
                        "description": "Fecha de fin en formato YYYY-MM-DD. Por defecto es hoy."
                    },
                    "limite": {
                        "type": "integer",
                        "description": "Número máximo de conversaciones a analizar",
                        "default": 20
                    }
                }
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

        message = None
        if not filtered:
            message = f"No encontré conversaciones entre {fecha_inicio} y {fecha_fin}"

        return {
            "conversaciones": filtered[:limite],
            "total": len(filtered),
            "fecha_inicio": fecha_inicio,
            "fecha_fin": fecha_fin,
            "message": message,
        }
    except Exception as e:
        return {"error": str(e), "conversaciones": [], "message": f"Error al buscar conversaciones: {str(e)}"}


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

        message = None
        if not formatted:
            message = f"No encontré conversaciones relacionadas con '{query}'"

        return {
            "query": query,
            "resultados": formatted,
            "total": len(formatted),
            "message": message,
        }
    except Exception as e:
        return {"error": str(e), "resultados": [], "message": f"Error en búsqueda semántica: {str(e)}"}


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

    elif tool_name == "resumen_dia":
        result = await get_day_summary(
            user_id=user_id,
            fecha=args.get("fecha"),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "obtener_action_items":
        result = await get_action_items(
            user_id=user_id,
            fecha_inicio=args.get("fecha_inicio"),
            fecha_fin=args.get("fecha_fin"),
            texto_busqueda=args.get("texto_busqueda"),
            limite=args.get("limite", 20),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "buscar_por_categoria":
        result = await search_by_category(
            user_id=user_id,
            categoria=args["categoria"],
            fecha_inicio=args.get("fecha_inicio"),
            fecha_fin=args.get("fecha_fin"),
            limite=args.get("limite", 10),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "estadisticas_uso":
        result = await get_user_metrics(
            user_id=user_id,
            period=args.get("periodo", "monthly"),
        )
        return json.dumps(result, default=str, ensure_ascii=False)

    elif tool_name == "feedback_comunicacion":
        result = await get_communication_feedback_aggregate(
            user_id=user_id,
            fecha_inicio=args.get("fecha_inicio"),
            fecha_fin=args.get("fecha_fin"),
            limite=args.get("limite", 20),
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
