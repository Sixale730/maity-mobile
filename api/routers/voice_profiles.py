"""Voice profile router - enrollment and verification endpoints"""
import os
import base64
from typing import Optional, Dict

import httpx
from pydantic import BaseModel, Field
from fastapi import APIRouter, HTTPException, UploadFile, File, Form, Depends

from ..services.supabase_client import get_supabase
from ..services.supabase_auth import optional_auth_user_id


router = APIRouter(prefix="/v1/voice", tags=["voice-profiles"])

# Modal.com endpoint URL (set in Vercel env vars)
# Format: https://workspace--app-name (e.g., https://divertido--maity-voice-embeddings)
MODAL_VOICE_URL = os.getenv("MODAL_VOICE_ENDPOINT_URL")

# Timeouts for Modal requests
ENROLL_TIMEOUT = 120.0  # 2 minutes for enrollment
VERIFY_TIMEOUT = 180.0  # 3 minutes for multi-speaker verification


def _get_modal_endpoint(function_name: str) -> str:
    """Build Modal endpoint URL from function name.

    Modal URLs format: https://workspace--app-name-function-name.modal.run
    Function names use dashes instead of underscores.
    """
    if not MODAL_VOICE_URL:
        return ""
    # Convert function_name underscores to dashes for Modal URL format
    function_slug = function_name.replace("_", "-")
    return f"{MODAL_VOICE_URL}-{function_slug}.modal.run"


# ============ Request/Response Models ============


class EnrollmentResponse(BaseModel):
    """Response from voice enrollment"""
    success: bool
    message: str
    embedding_dimensions: int = 192


class VerifySpeakersRequest(BaseModel):
    """Request to verify multiple speakers against user's profile"""
    user_id: str  # maity.users UUID
    speaker_segments: Dict[str, str]  # {speaker_id: audio_base64}
    sample_rate: int = 16000
    threshold: float = 0.75


class SpeakerResult(BaseModel):
    """Result for a single speaker verification"""
    is_user: bool
    similarity: float
    error: Optional[str] = None


class VerifySpeakersResponse(BaseModel):
    """Response from speaker verification"""
    results: Dict[str, SpeakerResult]


class VoiceProfileStatus(BaseModel):
    """Status of user's voice profile"""
    has_profile: bool
    created_at: Optional[str] = None
    quality_score: Optional[float] = None


class DeleteResponse(BaseModel):
    """Response from profile deletion"""
    success: bool
    message: str


# ============ Helper Functions ============


async def _call_modal_extract(audio_bytes: bytes, sample_rate: int = 16000) -> Optional[list]:
    """Call Modal.com to extract voice embedding."""
    endpoint = _get_modal_endpoint("extract_embedding_http")
    if not endpoint:
        print("[VoiceProfiles] MODAL_VOICE_ENDPOINT_URL not configured")
        return None

    try:
        async with httpx.AsyncClient(timeout=ENROLL_TIMEOUT) as client:
            response = await client.post(
                endpoint,
                json={
                    "audio_base64": base64.b64encode(audio_bytes).decode(),
                    "sample_rate": sample_rate,
                }
            )
            response.raise_for_status()
            data = response.json()

            if "error" in data:
                print(f"[VoiceProfiles] Modal error: {data['error']}")
                return None

            return data.get("embedding")
    except httpx.HTTPError as e:
        print(f"[VoiceProfiles] Modal HTTP error: {e}")
        return None
    except Exception as e:
        print(f"[VoiceProfiles] Modal error: {e}")
        return None


async def _call_modal_verify(
    user_embedding: list,
    speaker_segments: Dict[str, str],
    sample_rate: int = 16000,
    threshold: float = 0.75,
) -> Optional[Dict]:
    """Call Modal.com to verify speakers against user profile."""
    endpoint = _get_modal_endpoint("verify_speakers_http")
    if not endpoint:
        print("[VoiceProfiles] MODAL_VOICE_ENDPOINT_URL not configured")
        return None

    try:
        async with httpx.AsyncClient(timeout=VERIFY_TIMEOUT) as client:
            response = await client.post(
                endpoint,
                json={
                    "user_embedding": user_embedding,
                    "speaker_segments": speaker_segments,
                    "sample_rate": sample_rate,
                    "threshold": threshold,
                }
            )
            response.raise_for_status()
            data = response.json()

            if "error" in data:
                print(f"[VoiceProfiles] Modal error: {data['error']}")
                return None

            return data.get("results")
    except httpx.HTTPError as e:
        print(f"[VoiceProfiles] Modal HTTP error: {e}")
        return None
    except Exception as e:
        print(f"[VoiceProfiles] Modal error: {e}")
        return None


# ============ Endpoints ============


@router.post("/enroll", response_model=EnrollmentResponse)
async def enroll_voice_profile(
    user_id: str = Form(..., description="UUID from maity.users"),
    audio: UploadFile = File(..., description="Audio WAV 16kHz mono"),
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Enrollment: Create or update user's voice profile.

    Audio requirements:
    - Format: WAV (16-bit PCM)
    - Sample rate: 16kHz
    - Channels: Mono
    - Duration: 10-60 seconds of speech (30+ recommended)

    The endpoint:
    1. Sends audio to Modal.com for ECAPA-TDNN embedding extraction
    2. Stores the 192-dim embedding in Supabase voice_profiles table
    """
    if not MODAL_VOICE_URL:
        raise HTTPException(
            status_code=503,
            detail="Voice service not configured. Set MODAL_VOICE_ENDPOINT_URL."
        )

    # Read and validate audio
    audio_bytes = await audio.read()

    # Minimum ~2 seconds at 16kHz, 16-bit mono
    min_bytes = 16000 * 2 * 2
    if len(audio_bytes) < min_bytes:
        raise HTTPException(
            status_code=400,
            detail=f"Audio too short. Need at least 2 seconds ({min_bytes} bytes), got {len(audio_bytes)}."
        )

    # Calculate approximate duration
    duration_seconds = len(audio_bytes) / (16000 * 2)  # 16kHz, 16-bit

    print(f"[VoiceProfiles] Enrolling user {user_id}, audio duration: {duration_seconds:.1f}s")

    # Extract embedding from Modal
    embedding = await _call_modal_extract(audio_bytes, sample_rate=16000)

    if not embedding:
        raise HTTPException(
            status_code=503,
            detail="Failed to extract voice embedding. Voice service may be unavailable."
        )

    if len(embedding) != 192:
        raise HTTPException(
            status_code=500,
            detail=f"Invalid embedding dimensions: expected 192, got {len(embedding)}"
        )

    # Get auth_id from user
    supabase = get_supabase()

    try:
        user_result = (
            supabase.schema("maity")
            .table("users")
            .select("auth_id")
            .eq("id", user_id)
            .single()
            .execute()
        )
        auth_id = user_result.data.get("auth_id") if user_result.data else None
    except Exception:
        auth_id = None

    # Upsert voice profile
    try:
        supabase.schema("maity").table("voice_profiles").upsert(
            {
                "user_id": user_id,
                "auth_id": auth_id,
                "embedding": embedding,
                "enrollment_duration_seconds": duration_seconds,
                "samples_count": 1,
                "is_active": True,
            },
            on_conflict="user_id"
        ).execute()
    except Exception as e:
        print(f"[VoiceProfiles] Supabase error: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to save profile: {str(e)}")

    print(f"[VoiceProfiles] Profile created for user {user_id}")

    return EnrollmentResponse(
        success=True,
        message="Voice profile created successfully",
        embedding_dimensions=192,
    )


@router.post("/verify-speakers", response_model=VerifySpeakersResponse)
async def verify_speakers(
    request: VerifySpeakersRequest,
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """
    Verify multiple speakers against user's voice profile.

    Used when a conversation ends to re-label is_user in segments.
    Each speaker_segment should be base64-encoded PCM audio (16kHz, 16-bit, mono).

    Returns verification results for each speaker with:
    - is_user: True if similarity >= threshold
    - similarity: Cosine similarity score (0-1)
    """
    if not MODAL_VOICE_URL:
        # Fallback: speaker_0 is user
        return VerifySpeakersResponse(
            results={
                speaker_id: SpeakerResult(is_user=(speaker_id == "0"), similarity=0.0)
                for speaker_id in request.speaker_segments.keys()
            }
        )

    # Get user's voice profile
    supabase = get_supabase()

    try:
        profile_result = (
            supabase.schema("maity")
            .table("voice_profiles")
            .select("embedding")
            .eq("user_id", request.user_id)
            .eq("is_active", True)
            .single()
            .execute()
        )
    except Exception:
        profile_result = None

    if not profile_result or not profile_result.data:
        # No profile - fallback to speaker_0 = user
        print(f"[VoiceProfiles] No profile for user {request.user_id}, using fallback")
        return VerifySpeakersResponse(
            results={
                speaker_id: SpeakerResult(is_user=(speaker_id == "0"), similarity=0.0)
                for speaker_id in request.speaker_segments.keys()
            }
        )

    user_embedding = profile_result.data["embedding"]

    # Call Modal for verification
    modal_results = await _call_modal_verify(
        user_embedding=user_embedding,
        speaker_segments=request.speaker_segments,
        sample_rate=request.sample_rate,
        threshold=request.threshold,
    )

    if not modal_results:
        # Modal failed - fallback
        print(f"[VoiceProfiles] Modal verification failed, using fallback")
        return VerifySpeakersResponse(
            results={
                speaker_id: SpeakerResult(is_user=(speaker_id == "0"), similarity=0.0)
                for speaker_id in request.speaker_segments.keys()
            }
        )

    # Convert Modal results to response model
    results = {}
    for speaker_id, result in modal_results.items():
        results[speaker_id] = SpeakerResult(
            is_user=result.get("is_user", False),
            similarity=result.get("similarity", 0.0),
            error=result.get("error"),
        )

    print(f"[VoiceProfiles] Verification complete: {results}")

    return VerifySpeakersResponse(results=results)


@router.get("/status", response_model=VoiceProfileStatus)
async def get_profile_status(
    user_id: str,
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Check if user has an active voice profile."""
    supabase = get_supabase()

    try:
        result = (
            supabase.schema("maity")
            .table("voice_profiles")
            .select("created_at, quality_score")
            .eq("user_id", user_id)
            .eq("is_active", True)
            .single()
            .execute()
        )

        if result.data:
            return VoiceProfileStatus(
                has_profile=True,
                created_at=result.data.get("created_at"),
                quality_score=result.data.get("quality_score"),
            )
    except Exception:
        pass

    return VoiceProfileStatus(has_profile=False)


@router.delete("/profile", response_model=DeleteResponse)
async def delete_voice_profile(
    user_id: str,
    auth_user_id: Optional[str] = Depends(optional_auth_user_id),
):
    """Delete user's voice profile."""
    supabase = get_supabase()

    try:
        supabase.schema("maity").table("voice_profiles").delete().eq(
            "user_id", user_id
        ).execute()

        return DeleteResponse(success=True, message="Voice profile deleted")
    except Exception as e:
        print(f"[VoiceProfiles] Delete error: {e}")
        raise HTTPException(status_code=500, detail=str(e))
