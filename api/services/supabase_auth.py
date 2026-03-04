"""Supabase JWT authentication service — JWKS (ES256) + HS256 fallback"""
import os
from typing import Optional
from fastapi import Header, HTTPException
import jwt
from jwt import PyJWKClient

SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_JWT_SECRET = os.getenv("SUPABASE_JWT_SECRET", "")

if not SUPABASE_URL:
    print("[supabase_auth] WARNING: SUPABASE_URL not set — JWT verification will fail")

# PyJWKClient caches the JWKS for 5 minutes (persists across Vercel warm instances)
jwks_client: Optional[PyJWKClient] = None


def _get_jwks_client() -> PyJWKClient:
    """Lazy-init JWKS client (SUPABASE_URL may not be set at import time on Vercel)."""
    global jwks_client
    if jwks_client is None:
        url = f"{os.getenv('SUPABASE_URL', '')}/auth/v1/.well-known/jwks.json"
        jwks_client = PyJWKClient(url, cache_jwk_set=True, lifespan=300)
    return jwks_client


def _decode_token(token: str) -> dict:
    """Decode JWT using JWKS endpoint (ES256), with HS256 fallback.

    Strategy:
    1. JWKS (ES256) — primary, retries once with cache invalidation
    2. HS256 fallback — for legacy tokens signed before key rotation
    """
    global jwks_client
    last_jwks_error = None

    # --- Primary: JWKS (ES256) ---
    for attempt in range(2):
        try:
            client = _get_jwks_client()
            signing_key = client.get_signing_key_from_jwt(token)
            return jwt.decode(
                token,
                signing_key.key,
                algorithms=["ES256"],
                audience="authenticated",
            )
        except Exception as e:
            last_jwks_error = e
            print(f"[supabase_auth] JWKS verification failed (attempt {attempt + 1}): {type(e).__name__}: {e}")
            if attempt == 0:
                # Invalidate JWKS cache and retry with fresh keys
                jwks_client = None
                print("[supabase_auth] Invalidated JWKS cache, retrying with fresh keys...")

    # --- Fallback: HS256 (legacy tokens) ---
    if SUPABASE_JWT_SECRET:
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") == "HS256":
                print("[supabase_auth] Attempting HS256 fallback for legacy token...")
                payload = jwt.decode(
                    token,
                    SUPABASE_JWT_SECRET,
                    algorithms=["HS256"],
                    audience="authenticated",
                )
                print("[supabase_auth] HS256 fallback succeeded")
                return payload
            else:
                print(f"[supabase_auth] Token alg is {header.get('alg')}, skipping HS256 fallback")
        except jwt.ExpiredSignatureError:
            print("[supabase_auth] HS256 fallback: token expired")
            raise
        except Exception as e:
            print(f"[supabase_auth] HS256 fallback failed: {type(e).__name__}: {e}")
    else:
        print("[supabase_auth] SUPABASE_JWT_SECRET not set, skipping HS256 fallback")

    # Log token header for debugging (header is not secret)
    try:
        header = jwt.get_unverified_header(token)
        print(f"[supabase_auth] Token header: alg={header.get('alg')}, kid={header.get('kid')}")
    except Exception:
        print("[supabase_auth] Could not decode token header")

    raise jwt.InvalidTokenError(f"JWKS verification failed: {last_jwks_error}")


async def verify_supabase_token(
    authorization: str = Header(..., description="Bearer token"),
) -> dict:
    """
    Verify Supabase JWT token and return the payload.

    The token contains:
    - sub: auth.users.id (UUID)
    - email: user's email
    - role: authenticated
    - aud: authenticated

    Raises HTTPException 401 if token is invalid or expired.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header required")

    # Extract token from Bearer scheme
    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(status_code=401, detail="Invalid authorization header format")

    token = parts[1]

    try:
        return _decode_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=401,
            detail=f"Invalid or expired token: {str(e)}",
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Auth configuration error: {str(e)}",
        )


async def get_auth_user_id(
    authorization: str = Header(..., description="Bearer token"),
) -> str:
    """
    Verify token and return the auth.users.id (UUID).

    This is a convenience function that extracts just the user ID
    from the token payload.
    """
    payload = await verify_supabase_token(authorization)

    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=401, detail="Token missing user ID")

    return user_id


async def optional_auth_user_id(
    authorization: Optional[str] = Header(None, description="Bearer token"),
) -> Optional[str]:
    """
    Optionally verify token and return the auth.users.id (UUID).

    Returns None if no authorization header is provided.
    Raises HTTPException if token is provided but invalid.
    """
    if not authorization:
        return None

    return await get_auth_user_id(authorization)


def get_user_from_token(authorization: str = Header(...)) -> dict:
    """Extract user info from JWT token.

    Returns {"auth_id": sub, "email": email}.
    Compatible with FastAPI Depends().
    """
    try:
        if not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Invalid authorization header")

        token = authorization.replace("Bearer ", "")
        payload = _decode_token(token)

        return {
            "auth_id": payload.get("sub"),
            "email": payload.get("email"),
        }
    except HTTPException:
        raise
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")


async def resolve_maity_user_id(auth_id: str) -> str:
    """Resolve auth.users.id (from JWT sub) to maity.users.id.

    Queries maity.users by auth_id and returns the maity user UUID.
    Raises 403 if the user is not found in maity.users.
    """
    from .supabase_client import get_supabase

    supabase = get_supabase()
    result = (
        supabase.schema("maity")
        .table("users")
        .select("id")
        .eq("auth_id", auth_id)
        .single()
        .execute()
    )
    if not result.data or not result.data.get("id"):
        raise HTTPException(status_code=403, detail="User not found in maity.users")
    return result.data["id"]


async def verify_conversation_ownership(conversation_id: str, maity_user_id: str) -> dict:
    """Verify that a conversation belongs to the authenticated user.

    Returns the conversation row if ownership is confirmed.
    Raises 404 if conversation not found, 403 if not owned by user.
    """
    from .supabase_client import get_supabase

    supabase = get_supabase()
    result = (
        supabase.schema("maity")
        .table("omi_conversations")
        .select("id, user_id, status")
        .eq("id", conversation_id)
        .single()
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=404, detail="Conversation not found")
    if result.data.get("user_id") != maity_user_id:
        raise HTTPException(status_code=403, detail="Not authorized to access this conversation")
    return result.data
