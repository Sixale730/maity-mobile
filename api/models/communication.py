"""Pydantic models for communication feedback analysis - 6 competency standard"""
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


# ============ New 6-Competency Standard Models ============


class Radiografia(BaseModel):
    """X-ray of communication metrics"""
    muletillas_detectadas: Dict[str, int] = Field(default_factory=dict)
    muletillas_total: int = 0
    muletillas_frecuencia: str = ""  # e.g. "1 cada 45 palabras"
    ratio_habla: str = ""  # e.g. "65% usuario / 35% otros"
    palabras_usuario: int = 0
    palabras_otros: int = 0


class Preguntas(BaseModel):
    """Question analysis"""
    preguntas_usuario: List[str] = Field(default_factory=list)
    preguntas_otros: List[str] = Field(default_factory=list)
    total_usuario: int = 0
    total_otros: int = 0


class AccionUsuario(BaseModel):
    """User commitment/action from conversation"""
    descripcion: str = ""
    tiene_fecha: bool = False


class TemaSinCerrar(BaseModel):
    """Unresolved topic"""
    tema: str = ""
    razon: str = ""


class Temas(BaseModel):
    """Topics, commitments, and unresolved items"""
    temas_tratados: List[str] = Field(default_factory=list)
    acciones_usuario: List[AccionUsuario] = Field(default_factory=list)
    temas_sin_cerrar: List[TemaSinCerrar] = Field(default_factory=list)


class Patron(BaseModel):
    """Communication pattern analysis"""
    actual: str = ""  # Current pattern description
    evolucion: str = ""  # Evolution over conversation
    senales: List[str] = Field(default_factory=list)  # 3 key signals
    que_cambiaria: str = ""  # What to change


class CommunicationInsight(BaseModel):
    """What you might not have noticed"""
    dato: str = ""  # The observation
    por_que: str = ""  # Why it matters
    sugerencia: str = ""  # Concrete suggestion


class CommunicationFeedback(BaseModel):
    """Communication feedback with 6 competency scores + rich analysis"""
    # Legacy fields (kept for backward compatibility)
    strengths: List[str] = Field(default_factory=list)
    areas_to_improve: List[str] = Field(default_factory=list)
    observations: CommunicationObservations = Field(default_factory=CommunicationObservations)
    summary: str = ""
    counters: Optional[CommunicationCounters] = Field(default=None)

    # New 6-competency scores (0-10)
    overall_score: float = 0.0
    clarity: float = 0.0
    structure: float = 0.0
    vocabulario: float = 0.0
    empatia: float = 0.0
    objetivo: float = 0.0
    adaptacion: float = 0.0

    # New rich analysis fields
    feedback: str = ""  # Brief general feedback text
    radiografia: Optional[Radiografia] = Field(default=None)
    preguntas: Optional[Preguntas] = Field(default=None)
    temas: Optional[Temas] = Field(default=None)
    patron: Optional[Patron] = Field(default=None)
    insights: List[CommunicationInsight] = Field(default_factory=list)


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
