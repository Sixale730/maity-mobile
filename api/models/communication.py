"""Pydantic models for communication feedback analysis"""
from typing import List, Optional, Dict
from pydantic import BaseModel, Field


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
