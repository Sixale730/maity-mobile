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
from .supabase_auth import (
    verify_supabase_token,
    get_auth_user_id,
    optional_auth_user_id,
    get_user_from_token,
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
    "verify_supabase_token",
    "get_auth_user_id",
    "optional_auth_user_id",
    "get_user_from_token",
]
