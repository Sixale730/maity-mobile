"""Pydantic models for communication feedback analysis"""
from typing import List, Optional, Dict
from pydantic import BaseModel, Field


class CommunicationCounters(BaseModel):
    """Quantitative metrics about communication patterns"""
    pero_count: int = 0
    objection_words: Dict[str, int] = Field(default_factory=dict)  # {"pero": 5, "sin embargo": 2}
    objections_received: List[str] = Field(default_factory=list)  # Objections from the other person
    objections_made: List[str] = Field(default_factory=list)  # Objections made by user
    filler_words: Dict[str, int] = Field(default_factory=dict)  # {"este": 3, "o sea": 2}


class CommunicationObservations(BaseModel):
    """Observations about different aspects of communication"""
    clarity: str = ""
    structure: str = ""
    calls_to_action: str = ""
    objections: str = ""


class CommunicationFeedback(BaseModel):
    """Qualitative feedback about user's communication style"""
    strengths: List[str] = Field(default_factory=list)
    areas_to_improve: List[str] = Field(default_factory=list)
    observations: CommunicationObservations = Field(default_factory=CommunicationObservations)
    summary: str = ""
    counters: Optional[CommunicationCounters] = Field(default=None)


class AggregatedFeedback(BaseModel):
    """Aggregated communication feedback across multiple conversations"""
    top_strengths: List[str] = Field(default_factory=list)
    top_areas_to_improve: List[str] = Field(default_factory=list)
    observations_summary: CommunicationObservations = Field(default_factory=CommunicationObservations)
    conversations_analyzed: int = 0
    period: str = ""


class CommunicationFeedbackRequest(BaseModel):
    """Request to get aggregated communication feedback"""
    user_id: str
    period: str = "monthly"  # today, weekly, monthly, yearly, all


class CommunicationFeedbackResponse(BaseModel):
    """Response with aggregated communication feedback"""
    user_id: str
    period: str
    feedback: AggregatedFeedback
