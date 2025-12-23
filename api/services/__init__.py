"""Services package"""
from .openai_processor import (
    process_conversation,
    count_words,
    calculate_duration,
    count_insights,
)
from .firebase_client import (
    get_db,
    save_conversation,
    update_user_metrics,
    get_user_metrics,
    get_user_conversations,
)

__all__ = [
    "process_conversation",
    "count_words",
    "calculate_duration",
    "count_insights",
    "get_db",
    "save_conversation",
    "update_user_metrics",
    "get_user_metrics",
    "get_user_conversations",
]
