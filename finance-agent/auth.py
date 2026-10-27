"""JWT auth for FinanceAgent using Keycloak.

Reads the Bearer token from the Authorization header, verifies the RS256
signature against the Keycloak realm JWKS, and validates expiry, issuer and
expected audience. require_agent_user additionally requires the roles that
allow use of the assistant. Denials are logged without the token.

Environment variables:
- KEYCLOAK_URL (Keycloak URL reachable from this service)
- KEYCLOAK_ISSUER (issuer URL present in access tokens)
- KEYCLOAK_REALM (e.g., banking)
- KEYCLOAK_AUDIENCE (e.g., banking-api)
- KEYCLOAK_ROLE_CLIENT_ID (client whose roles are honoured besides realm roles; banking-frontend)
- FINANCE_AGENT_REQUIRED_ROLES (comma-separated; banking-customer,banking-ai-agent)
"""
from __future__ import annotations
import logging
import os
from functools import lru_cache
from typing import Any, Dict

from fastapi import Depends, Header, HTTPException, Request, status
import jwt

security_log = logging.getLogger("security.audit")


class UserContext(Dict[str, Any]):
    @property
    def user_id(self) -> str:
        return self.get("user_id", "")

    @property
    def roles(self) -> frozenset[str]:
        return frozenset(self.get("roles", ()))


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
def _role_client_id() -> str:
    return _get_env("KEYCLOAK_ROLE_CLIENT_ID", "banking-frontend")


@lru_cache(maxsize=1)
def required_roles() -> frozenset[str]:
    configured = _get_env("FINANCE_AGENT_REQUIRED_ROLES", "banking-customer,banking-ai-agent")
    return frozenset(role.strip() for role in configured.split(",") if role.strip())


@lru_cache(maxsize=1)
def _jwks_client() -> jwt.PyJWKClient:
    # Keys are cached; an unknown key ID triggers one refetch, so Keycloak key rotation is picked up.
    return jwt.PyJWKClient(_jwks_uri(), cache_keys=True, lifespan=300, timeout=5)


def _decode_token(token: str) -> Dict[str, Any]:
    try:
        key = _jwks_client().get_signing_key_from_jwt(token)
    except jwt.PyJWKClientConnectionError as exc:
        security_log.error("jwks_unavailable uri=%s", _jwks_uri())
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail="Unable to fetch Keycloak JWKS") from exc
    except (jwt.PyJWKClientError, jwt.InvalidTokenError) as exc:
        raise _unauthorized(f"{type(exc).__name__}: {exc}") from exc

    try:
        return jwt.decode(
            token,
            key=key.key,
            algorithms=["RS256"],
            audience=_audience(),
            issuer=_issuer(),
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            leeway=30,
        )
    except jwt.ExpiredSignatureError as exc:
        raise _unauthorized("token expired", "Token expired") from exc
    except jwt.InvalidIssuerError as exc:
        raise _unauthorized("invalid issuer", "Invalid issuer") from exc
    except jwt.InvalidAudienceError as exc:
        raise _unauthorized("invalid audience", "Invalid token audience") from exc
    except jwt.InvalidTokenError as exc:
        raise _unauthorized(f"{type(exc).__name__}: {exc}") from exc


def _unauthorized(reason: str, detail: str = "Invalid token") -> HTTPException:
    security_log.warning('authentication_failed service=finance-agent reason="%s"', reason)
    return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=detail,
                         headers={"WWW-Authenticate": "Bearer"})


def user_from_token(token: str) -> UserContext:
    payload = _decode_token(token)
    subject = payload.get("sub")
    user_id = payload.get("preferred_username")
    if not subject or not user_id:
        raise _unauthorized("token has no subject or preferred_username",
                            "Token must contain a subject and bank user ID")
    roles = set(payload.get("realm_access", {}).get("roles", []))
    roles.update(payload.get("resource_access", {}).get(_role_client_id(), {}).get("roles", []))
    return UserContext(user_id=str(user_id), subject=str(subject), token=token, roles=frozenset(roles))


def require_user(authorization: str | None = Header(default=None, alias="Authorization")) -> UserContext:
    if not authorization or not authorization.startswith("Bearer "):
        raise _unauthorized("missing bearer token", "Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise _unauthorized("missing bearer token", "Missing bearer token")
    return user_from_token(token)


def require_agent_user(request: Request, user: UserContext = Depends(require_user)) -> UserContext:
    """An authenticated user who also holds every role required to use the assistant."""
    missing = required_roles() - user.roles
    if missing:
        security_log.warning(
            'authorization_denied service=finance-agent method=%s path=%s user=%s subject=%s reason="missing role"',
            request.method, request.url.path, user.user_id, user.get("subject"),
        )
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access denied")
    return user


# Helper for tests to bypass network/keycloak by overriding the dependency
def fake_user(user_id: str = "test-user", roles=("banking-customer", "banking-ai-agent")) -> UserContext:  # pragma: no cover
    return UserContext(user_id=user_id, subject="test-subject", token="test-token", roles=frozenset(roles))
