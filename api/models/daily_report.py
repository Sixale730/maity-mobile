"""Pydantic models for daily communication reports"""
from typing import List, Optional, Dict
from pydantic import BaseModel, Field


class DailyScores(BaseModel):
    """Communication scores for a daily report - 6 competency standard"""
    clarity: float = 0.0
    structure: float = 0.0
    vocabulario: float = 0.0
    empatia: float = 0.0
    objetivo: float = 0.0
    adaptacion: float = 0.0
    # Legacy fields (kept for backward compat)
    calls_to_action: float = 0.0
    objection_handling: float = 0.0
    overall: float = 0.0


class DailyTrend(BaseModel):
    """Trend information comparing to previous report"""
    trend: str = "first_report"  # improving, stable, declining, first_report
    previous_overall: Optional[float] = None
    change: Optional[float] = None


class DailyCommunicationReport(BaseModel):
    """Full daily communication report"""
    id: Optional[str] = None
    user_id: str
    report_date: str
    conversations_analyzed: int = 0
    total_words_analyzed: int = 0
    total_duration_seconds: int = 0
    total_filler_words: Dict[str, int] = Field(default_factory=dict)
    total_filler_count: int = 0
    total_pero_count: int = 0
    total_objection_words: Dict[str, int] = Field(default_factory=dict)
    objections_received: List[str] = Field(default_factory=list)
    objections_made: List[str] = Field(default_factory=list)
    scores: DailyScores = Field(default_factory=DailyScores)
    top_strengths: List[str] = Field(default_factory=list)
    top_areas_to_improve: List[str] = Field(default_factory=list)
    daily_summary: str = ""
    recommendations: List[str] = Field(default_factory=list)
    trend: DailyTrend = Field(default_factory=DailyTrend)
    conversation_ids: List[str] = Field(default_factory=list)
    created_at: Optional[str] = None
