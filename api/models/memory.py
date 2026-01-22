"""Pydantic models for memories"""
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field
from enum import Enum


class MemoryCategory(str, Enum):
    """Categories for memories"""
    INTERESTING = "interesting"  # Auto-extracted interesting facts
    SYSTEM = "system"            # System-generated metadata
    MANUAL = "manual"            # User-created memories


class MemoryVisibility(str, Enum):
    """Visibility settings for memories"""
    PRIVATE = "private"
    PUBLIC = "public"


class Memory(BaseModel):
    """A memory extracted from or related to a conversation"""
    id: Optional[str] = None
    user_id: Optional[str] = None
    auth_id: Optional[str] = None
    conversation_id: Optional[str] = None
    content: str
    category: MemoryCategory = MemoryCategory.INTERESTING
    reviewed: bool = False
    user_review: Optional[bool] = None  # True=approved, False=rejected, None=pending
    manually_added: bool = False
    edited: bool = False
    deleted: bool = False
    visibility: MemoryVisibility = MemoryVisibility.PRIVATE
    is_locked: bool = False
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class CreateMemoryRequest(BaseModel):
    """Request to create a memory manually"""
    content: str
    category: MemoryCategory = MemoryCategory.MANUAL
    conversation_id: Optional[str] = None
    visibility: MemoryVisibility = MemoryVisibility.PRIVATE


class UpdateMemoryRequest(BaseModel):
    """Request to update a memory"""
    content: Optional[str] = None
    visibility: Optional[MemoryVisibility] = None


class ReviewMemoryRequest(BaseModel):
    """Request to review a memory"""
    approved: bool  # True to approve, False to reject


class ExtractMemoriesRequest(BaseModel):
    """Request to extract memories from a conversation"""
    conversation_id: str


class ExtractMemoriesResponse(BaseModel):
    """Response from extracting memories"""
    conversation_id: str
    memories_created: int
    memories: List[Memory]


class MemoryListResponse(BaseModel):
    """Response with list of memories"""
    memories: List[Memory]
    total: int
    pending_review: int


class SearchMemoriesRequest(BaseModel):
    """Request to search memories semantically"""
    query: str
    limit: int = 10
    category: Optional[MemoryCategory] = None
    include_deleted: bool = False
