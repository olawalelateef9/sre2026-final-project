"""Keycloak access-token validation for banking APIs.

Checks the RS256 signature against the realm JWKS, expiry, issuer, audience and
the preferred_username claim, then exposes the caller's bank user ID and roles.
Roles come from realm_access and from the configured client's resource_access.

The same module is used by the user and activity services; keep the copies in sync.
"""
import logging
import os
from dataclasses import dataclass
from functools import lru_cache

import jwt
from fastapi import Depends, HTTPException, Request, status

security_log = logging.getLogger("security.audit")

USER_ID_CLAIM = "preferred_username"


@dataclass(frozen=True)
class Caller:
    user_id: str
    subject: str
    roles: frozenset[str]


@dataclass(frozen=True)
class Settings:
    issuer: str
    jwks_uri: str
    audience: str
    role_client_id: str


@lru_cache(maxsize=1)
def settings() -> Settings:
    issuer = os.getenv("KEYCLOAK_ISSUER", "http://localhost:8080/realms/banking").rstrip("/")
    return Settings(
        issuer=issuer,
        jwks_uri=os.getenv("KEYCLOAK_JWK_SET_URI", f"{issuer}/protocol/openid-connect/certs"),
        audience=os.getenv("KEYCLOAK_AUDIENCE", "banking-api"),
        role_client_id=os.getenv("KEYCLOAK_ROLE_CLIENT_ID", "banking-frontend"),
    )


@lru_cache(maxsize=1)
def _jwks_client() -> jwt.PyJWKClient:
    # Keys are cached; an unknown key ID triggers one refetch, so Keycloak key rotation is picked up.
    return jwt.PyJWKClient(settings().jwks_uri, cache_keys=True, lifespan=300, timeout=5)


def _reject(request: Request, reason: str) -> HTTPException:
    security_log.warning(
        'authentication_failed method=%s path=%s remote=%s reason="%s"',
        request.method, request.url.path, request.client.host if request.client else "unknown", reason,
    )
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing access token",
        headers={"WWW-Authenticate": "Bearer"},
    )


def authenticated_caller(request: Request) -> Caller:
    authorization = request.headers.get("Authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise _reject(request, "missing bearer token")

    config = settings()
    try:
        signing_key = _jwks_client().get_signing_key_from_jwt(token.strip())
        claims = jwt.decode(
            token.strip(),
            signing_key.key,
            algorithms=["RS256"],
            audience=config.audience,
            issuer=config.issuer,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            leeway=30,
        )
    except jwt.PyJWKClientConnectionError as error:
        security_log.error("jwks_unavailable uri=%s", config.jwks_uri)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail="Identity provider unavailable") from error
    except (jwt.PyJWKClientError, jwt.InvalidTokenError) as error:
        raise _reject(request, f"{type(error).__name__}: {error}") from error

    user_id = claims.get(USER_ID_CLAIM)
    if not isinstance(user_id, str) or not user_id.strip():
        raise _reject(request, f"token has no {USER_ID_CLAIM} claim")

    roles = set(claims.get("realm_access", {}).get("roles", []))
    roles.update(claims.get("resource_access", {}).get(config.role_client_id, {}).get("roles", []))
    return Caller(user_id=user_id, subject=str(claims["sub"]), roles=frozenset(roles))


def require_roles(*required: str):
    """Dependency factory: the caller must hold every listed role."""

    def dependency(request: Request, caller: Caller = Depends(authenticated_caller)) -> Caller:
        if not set(required) <= caller.roles:
            raise deny(request, caller, "missing role")
        return caller

    return dependency


def deny(request: Request, caller: Caller, reason: str) -> HTTPException:
    """Logs an authorization denial (never the token) and returns the 403 to raise."""
    security_log.warning(
        "authorization_denied method=%s path=%s remote=%s user=%s subject=%s reason=\"%s\"",
        request.method, request.url.path, request.client.host if request.client else "unknown",
        caller.user_id, caller.subject, reason,
    )
    return HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access denied")
