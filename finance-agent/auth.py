"""JWT auth for FinanceAgent using Keycloak.

Reads the Bearer token from the Authorization header, verifies the
signature against the Keycloak realm JWKS, and validates issuer and
expected audience. Returns a small user context with user_id and token.

Environment variables:
- KEYCLOAK_URL (Keycloak URL reachable from this service)
- KEYCLOAK_ISSUER (issuer URL present in access tokens)
- KEYCLOAK_REALM (e.g., banking)
- KEYCLOAK_AUDIENCE (e.g., banking-api)
"""
from __future__ import annotations
import os
from functools import lru_cache
from typing import Any, Dict

import httpx
from fastapi import Depends, Header, HTTPException, status
import jwt


class UserContext(Dict[str, Any]):
    @property
    def user_id(self) -> str:
        return self.get("user_id", "")


def _get_env(name: str, default: str = "") -> str:
    value = os.getenv(name, default).strip()
    if name in ("KEYCLOAK_URL", "KEYCLOAK_ISSUER") and value.endswith("/"):
        value = value[:-1]
    return value


@lru_cache(maxsize=1)
def _issuer() -> str:
    configured_issuer = _get_env("KEYCLOAK_ISSUER")
    if configured_issuer:
        return configured_issuer
    url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm = _get_env("KEYCLOAK_REALM", "banking")
    return f"{url}/realms/{realm}"


@lru_cache(maxsize=1)
def _jwks_uri() -> str:
    url = _get_env("KEYCLOAK_URL", "http://localhost:8080")
    realm = _get_env("KEYCLOAK_REALM", "banking")
    return f"{url}/realms/{realm}/protocol/openid-connect/certs"


@lru_cache(maxsize=1)
def _audience() -> str:
    return _get_env("KEYCLOAK_AUDIENCE", "banking-api")


@lru_cache(maxsize=1)
def _jwks() -> Dict[str, Any]:
    try:
        with httpx.Client(timeout=5.0) as http:
            resp = http.get(_jwks_uri())
            resp.raise_for_status()
            return resp.json()
    except Exception as exc:  # pragma: no cover (network issues)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail="Unable to fetch Keycloak JWKS") from exc


def _public_key_for_kid(kid: str) -> Dict[str, Any]:
    jwks = _jwks()
    for key in jwks.get("keys", []):
        if key.get("kid") == kid:
            return key
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token (unknown kid)")


def _decode_token(token: str) -> Dict[str, Any]:
    try:
        headers = jwt.get_unverified_header(token)
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from exc

    key = _public_key_for_kid(headers.get("kid", ""))
    try:
        payload = jwt.decode(
            token,
            key=jwt.algorithms.RSAAlgorithm.from_jwk(key),
            algorithms=["RS256"],
            audience=None,  # validate manually to accept list or string
            issuer=_issuer(),
            options={"verify_aud": False},
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired") from exc
    except jwt.InvalidIssuerError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid issuer") from exc
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from exc

    aud = payload.get("aud")
    expected = _audience()
    if isinstance(aud, str):
        valid_aud = (aud == expected)
    elif isinstance(aud, list):
        valid_aud = expected in aud
    else:
        valid_aud = False
    if not valid_aud:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token audience")
    return payload


def user_from_token(token: str) -> UserContext:
    payload = _decode_token(token)
    subject = payload.get("sub")
    user_id = payload.get("preferred_username") or payload.get("uid")
    if not subject or not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Token must contain a subject and bank user ID")
    return UserContext(user_id=str(user_id), subject=str(subject), token=token)


def require_user(authorization: str | None = Header(default=None, alias="Authorization")) -> UserContext:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    return user_from_token(token)


# Helper for tests to bypass network/keycloak by overriding the dependency
def fake_user(user_id: str = "test-user") -> UserContext:  # pragma: no cover
    return UserContext(user_id=user_id, subject="test-subject", token="test-token")
