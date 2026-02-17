"""Supabase JWT authentication service — JWKS (ES256) + HS256 fallback"""
import os
from typing import Optional
from fastapi import Header, HTTPException
import jwt
from jwt import PyJWKClient

SUPABASE_URL = os.getenv("SUPABASE_URL", "")
JWKS_URL = f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json"

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
    """Decode JWT using JWKS (primary) or HS256 secret (fallback).

    JWKS supports both ES256 (new ECC P-256 keys) and HS256 automatically.
    The HS256 fallback using SUPABASE_JWT_SECRET is a safety net during the
    key rotation transition period.
    """
    # Primary: JWKS endpoint
    try:
        client = _get_jwks_client()
        signing_key = client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["ES256", "HS256"],
            audience="authenticated",
        )
    except Exception:
        pass

    # Fallback: legacy HS256 shared secret
    jwt_secret = os.getenv("SUPABASE_JWT_SECRET")
    if jwt_secret:
        try:
            return jwt.decode(
                token,
                jwt_secret,
                algorithms=["HS256"],
                audience="authenticated",
            )
        except Exception:
            pass

    raise jwt.InvalidTokenError("Could not verify token with JWKS or HS256 secret")


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
