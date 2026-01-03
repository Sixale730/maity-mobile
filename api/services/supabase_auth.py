"""Supabase JWT authentication service"""
import os
from typing import Optional
from fastapi import Header, HTTPException
from jose import jwt, JWTError


def get_jwt_secret() -> str:
    """Get Supabase JWT secret from environment"""
    secret = os.getenv("SUPABASE_JWT_SECRET")
    if not secret:
        raise ValueError("SUPABASE_JWT_SECRET must be set")
    return secret


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
        jwt_secret = get_jwt_secret()

        # Decode and verify the JWT
        # Supabase uses HS256 algorithm
        payload = jwt.decode(
            token,
            jwt_secret,
            algorithms=["HS256"],
            audience="authenticated",
        )

        return payload

    except JWTError as e:
        raise HTTPException(
            status_code=401,
            detail=f"Invalid or expired token: {str(e)}",
        )
    except ValueError as e:
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
