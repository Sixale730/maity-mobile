"""Pydantic models for conversation processing"""
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field
from enum import Enum


class CategoryEnum(str, Enum):
    """32 categories based on Omi + custom"""
    PERSONAL = "personal"
    EDUCATION = "education"
    HEALTH = "health"
    FINANCE = "finance"
    LEGAL = "legal"
    PHILOSOPHY = "philosophy"
    SPIRITUAL = "spiritual"
    SCIENCE = "science"
    ENTREPRENEURSHIP = "entrepreneurship"
    PARENTING = "parenting"
    ROMANTIC = "romantic"
    TRAVEL = "travel"
    INSPIRATION = "inspiration"
    TECHNOLOGY = "technology"
    BUSINESS = "business"
    SOCIAL = "social"
    WORK = "work"
    SPORTS = "sports"
    POLITICS = "politics"
    LITERATURE = "literature"
    HISTORY = "history"
    ARCHITECTURE = "architecture"
    MUSIC = "music"
    WEATHER = "weather"
    NEWS = "news"
    ENTERTAINMENT = "entertainment"
    PSYCHOLOGY = "psychology"
    DESIGN = "design"
    FAMILY = "family"
    ECONOMICS = "economics"
    ENVIRONMENT = "environment"
    OTHER = "other"


class TranscriptSegment(BaseModel):
    """A segment of transcribed speech"""
    text: str
    speaker: Optional[str] = None
    speaker_id: Optional[int] = None
    is_user: bool = False
    start: float = 0.0
    end: float = 0.0


class ActionItem(BaseModel):
    """An action item extracted from conversation"""
    description: str
    completed: bool = False
    due_at: Optional[datetime] = None


class Event(BaseModel):
    """An event/appointment extracted from conversation"""
    title: str
    start: datetime
    duration_minutes: int = 30
    description: Optional[str] = None


class StructuredData(BaseModel):
    """Structured data extracted from conversation"""
    title: str
    emoji: str = "🎤"
    overview: str = ""
    category: CategoryEnum = CategoryEnum.OTHER
    action_items: List[ActionItem] = Field(default_factory=list)
    events: List[Event] = Field(default_factory=list)


class ConversationMetrics(BaseModel):
    """Metrics for a single conversation"""
    words_count: int = 0
    duration_seconds: int = 0
    insights_count: int = 0


class ProcessConversationRequest(BaseModel):
    """Request to process a conversation"""
    user_id: str
    transcript_segments: List[TranscriptSegment]
    started_at: datetime
    finished_at: datetime


class ProcessConversationResponse(BaseModel):
    """Response from processing a conversation"""
    id: str
    created_at: datetime
    started_at: datetime
    finished_at: datetime
    structured: StructuredData
    metrics: ConversationMetrics
    transcript_segments: List[TranscriptSegment]
