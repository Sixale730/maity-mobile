"""Pydantic models for user metrics"""
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field


class CategoryCount(BaseModel):
    """Count of conversations per category"""
    category: str
    count: int


class DailyMetrics(BaseModel):
    """Metrics for a single day"""
    date: str  # YYYY-MM-DD format
    conversations: int = 0
    minutes: float = 0.0
    words: int = 0
    insights: int = 0
    memories: int = 0


class UserStats(BaseModel):
    """Aggregated user statistics"""
    transcription_seconds: int = 0
    words_transcribed: int = 0
    conversations_count: int = 0
    insights_gained: int = 0
    memories_count: int = 0
    top_categories: List[CategoryCount] = Field(default_factory=list)


class UserMetricsResponse(BaseModel):
    """Response for user metrics endpoint"""
    period: str  # today, weekly, monthly, yearly, all
    user_id: str
    stats: UserStats
    history: List[DailyMetrics] = Field(default_factory=list)


class UpdateMetricsRequest(BaseModel):
    """Request to update metrics for a conversation"""
    user_id: str
    conversation_id: str
    duration_seconds: int
    words_count: int
    insights_count: int
    category: str
    created_at: datetime
