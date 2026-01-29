"""Routers package"""
from .conversations import router as conversations_router
from .metrics import router as metrics_router
from .action_items import router as action_items_router
from .omi import router as omi_router
from .voice_profiles import router as voice_profiles_router
from .communication import router as communication_router
from .messages import router as messages_router
from .feedback import router as feedback_router
from .memories import router as memories_router
from .daily_reports import router as daily_reports_router

__all__ = [
    "conversations_router",
    "metrics_router",
    "action_items_router",
    "omi_router",
    "voice_profiles_router",
    "communication_router",
    "messages_router",
    "feedback_router",
    "memories_router",
    "daily_reports_router",
]
