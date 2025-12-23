"""Firebase Firestore client service"""
import os
import json
from datetime import datetime, timedelta
from typing import List, Optional, Dict, Any
from collections import defaultdict

import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud.firestore_v1 import FieldFilter

from ..models.conversation import (
    ProcessConversationResponse,
    TranscriptSegment,
    StructuredData,
    ConversationMetrics,
)
from ..models.metrics import (
    UserMetricsResponse,
    UserStats,
    CategoryCount,
    DailyMetrics,
)


# Initialize Firebase
_app = None
_db = None


def get_db():
    """Get Firestore database instance"""
    global _app, _db

    if _db is None:
        # Get service account from environment
        service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT")

        if service_account_json:
            try:
                service_account = json.loads(service_account_json)
                cred = credentials.Certificate(service_account)
                _app = firebase_admin.initialize_app(cred)
            except Exception as e:
                print(f"[Firebase] Error initializing with service account: {e}")
                # Try default credentials (for local development)
                try:
                    _app = firebase_admin.initialize_app()
                except ValueError:
                    # App already initialized
                    pass
        else:
            # Use default credentials
            try:
                _app = firebase_admin.initialize_app()
            except ValueError:
                # App already initialized
                pass

        _db = firestore.client()

    return _db


async def save_conversation(
    user_id: str,
    conversation: ProcessConversationResponse,
) -> str:
    """
    Save a processed conversation to Firestore.

    Args:
        user_id: Firebase user ID
        conversation: Processed conversation data

    Returns:
        Conversation ID
    """
    db = get_db()

    # Convert to dict for Firestore
    conv_data = {
        "id": conversation.id,
        "created_at": conversation.created_at,
        "started_at": conversation.started_at,
        "finished_at": conversation.finished_at,
        "structured": {
            "title": conversation.structured.title,
            "emoji": conversation.structured.emoji,
            "overview": conversation.structured.overview,
            "category": conversation.structured.category.value,
            "action_items": [
                {
                    "description": item.description,
                    "completed": item.completed,
                    "due_at": item.due_at.isoformat() if item.due_at else None,
                }
                for item in conversation.structured.action_items
            ],
            "events": [
                {
                    "title": event.title,
                    "start": event.start.isoformat(),
                    "duration_minutes": event.duration_minutes,
                    "description": event.description,
                }
                for event in conversation.structured.events
            ],
        },
        "metrics": {
            "words_count": conversation.metrics.words_count,
            "duration_seconds": conversation.metrics.duration_seconds,
            "insights_count": conversation.metrics.insights_count,
        },
        # Compress transcript segments for storage
        "transcript_text": "\n".join([s.text for s in conversation.transcript_segments]),
        "segments_count": len(conversation.transcript_segments),
    }

    # Save to Firestore
    doc_ref = db.collection("users").document(user_id)\
                .collection("conversations").document(conversation.id)
    doc_ref.set(conv_data)

    # Update metrics
    await update_user_metrics(
        user_id=user_id,
        duration_seconds=conversation.metrics.duration_seconds,
        words_count=conversation.metrics.words_count,
        insights_count=conversation.metrics.insights_count,
        category=conversation.structured.category.value,
        created_at=conversation.created_at,
    )

    return conversation.id


async def update_user_metrics(
    user_id: str,
    duration_seconds: int,
    words_count: int,
    insights_count: int,
    category: str,
    created_at: datetime,
) -> None:
    """Update user metrics after a conversation"""
    db = get_db()

    # Get the hour key for hourly metrics
    hour_key = created_at.strftime("%Y-%m-%d-%H")
    date_key = created_at.strftime("%Y-%m-%d")

    # Update hourly metrics
    hourly_ref = db.collection("users").document(user_id)\
                   .collection("metrics").document(f"hourly_{hour_key}")

    # Use transaction for atomic update
    @firestore.transactional
    def update_in_transaction(transaction, doc_ref):
        doc = doc_ref.get(transaction=transaction)

        if doc.exists:
            data = doc.to_dict()
            data["transcription_seconds"] = data.get("transcription_seconds", 0) + duration_seconds
            data["words_transcribed"] = data.get("words_transcribed", 0) + words_count
            data["conversations_count"] = data.get("conversations_count", 0) + 1
            data["insights_gained"] = data.get("insights_gained", 0) + insights_count

            # Update category counts
            categories = data.get("categories", {})
            categories[category] = categories.get(category, 0) + 1
            data["categories"] = categories
        else:
            data = {
                "hour": hour_key,
                "date": date_key,
                "transcription_seconds": duration_seconds,
                "words_transcribed": words_count,
                "conversations_count": 1,
                "insights_gained": insights_count,
                "categories": {category: 1},
            }

        transaction.set(doc_ref, data)

    transaction = db.transaction()
    update_in_transaction(transaction, hourly_ref)


async def get_user_metrics(
    user_id: str,
    period: str = "monthly",
) -> UserMetricsResponse:
    """
    Get aggregated metrics for a user.

    Args:
        user_id: Firebase user ID
        period: today, weekly, monthly, yearly, all

    Returns:
        UserMetricsResponse with aggregated stats
    """
    db = get_db()

    # Calculate date range
    now = datetime.now()
    if period == "today":
        start_date = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif period == "weekly":
        start_date = now - timedelta(days=7)
    elif period == "monthly":
        start_date = now - timedelta(days=30)
    elif period == "yearly":
        start_date = now - timedelta(days=365)
    else:  # all
        start_date = datetime(2020, 1, 1)

    start_key = start_date.strftime("%Y-%m-%d")

    # Query hourly metrics
    metrics_ref = db.collection("users").document(user_id).collection("metrics")

    # Get all metrics docs that match the period
    docs = metrics_ref.where(filter=FieldFilter("date", ">=", start_key)).stream()

    # Aggregate
    total_seconds = 0
    total_words = 0
    total_conversations = 0
    total_insights = 0
    category_counts: Dict[str, int] = defaultdict(int)
    daily_data: Dict[str, Dict[str, Any]] = defaultdict(lambda: {"conversations": 0, "minutes": 0, "words": 0})

    for doc in docs:
        data = doc.to_dict()
        total_seconds += data.get("transcription_seconds", 0)
        total_words += data.get("words_transcribed", 0)
        total_conversations += data.get("conversations_count", 0)
        total_insights += data.get("insights_gained", 0)

        # Aggregate categories
        for cat, count in data.get("categories", {}).items():
            category_counts[cat] += count

        # Aggregate daily
        date = data.get("date", "unknown")
        daily_data[date]["conversations"] += data.get("conversations_count", 0)
        daily_data[date]["minutes"] += data.get("transcription_seconds", 0) / 60
        daily_data[date]["words"] += data.get("words_transcribed", 0)

    # Build response
    top_categories = sorted(
        [CategoryCount(category=cat, count=count) for cat, count in category_counts.items()],
        key=lambda x: x.count,
        reverse=True,
    )[:10]

    history = sorted(
        [
            DailyMetrics(
                date=date,
                conversations=d["conversations"],
                minutes=round(d["minutes"], 1),
                words=d["words"],
            )
            for date, d in daily_data.items()
        ],
        key=lambda x: x.date,
        reverse=True,
    )[:30]

    return UserMetricsResponse(
        period=period,
        user_id=user_id,
        stats=UserStats(
            transcription_seconds=total_seconds,
            words_transcribed=total_words,
            conversations_count=total_conversations,
            insights_gained=total_insights,
            top_categories=top_categories,
        ),
        history=history,
    )


async def get_user_conversations(
    user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """Get user's conversations"""
    db = get_db()

    docs = db.collection("users").document(user_id)\
             .collection("conversations")\
             .order_by("created_at", direction=firestore.Query.DESCENDING)\
             .limit(limit)\
             .offset(offset)\
             .stream()

    return [doc.to_dict() for doc in docs]
