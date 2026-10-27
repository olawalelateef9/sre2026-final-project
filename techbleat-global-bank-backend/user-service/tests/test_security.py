"""Acceptance criteria A4 (token rejection) and A5 (no cross-account access) for the user service."""
from unittest.mock import MagicMock, patch

import jwt
import pytest
from fastapi.testclient import TestClient

from conftest import UNTRUSTED_KEY, bearer, make_token
from app.main import app

client = TestClient(app)

INVALID_TOKENS = {
    "expired": lambda: make_token(expires_in=-600),
    "untrusted signing key": lambda: make_token(key=UNTRUSTED_KEY),
    "wrong issuer": lambda: make_token(issuer="https://evil.test/realms/banking"),
    "wrong audience": lambda: make_token(audience="account"),
    "no username": lambda: make_token(preferred_username=None, username=None),
    "unsigned (alg none)": lambda: jwt.encode({"preferred_username": "alice"}, None, algorithm="none"),
    "malformed": lambda: "not-a-jwt",
}


def profile_db(row):
    """Patches the engine so the profile query returns row; returns the patcher and mock connection."""
    conn = MagicMock()
    conn.execute.return_value.mappings.return_value.first.return_value = row
    engine = MagicMock()
    engine.begin.return_value.__enter__.return_value = conn
    return patch("app.main.engine", engine), conn


def test_health_is_public():
    assert client.get("/health").status_code == 200


def test_customer_directory_is_not_exposed():
    assert client.get("/users", headers=bearer(make_token())).status_code == 405


def test_missing_token_is_rejected():
    response = client.get("/users/me")
    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"


@pytest.mark.parametrize("case", INVALID_TOKENS)
def test_invalid_tokens_are_rejected(case):
    db, conn = profile_db({"id": "alice"})
    with db:
        response = client.get("/users/me", headers=bearer(INVALID_TOKENS[case]()))
    assert response.status_code == 401
    conn.execute.assert_not_called()


def test_token_without_customer_role_is_forbidden():
    db, conn = profile_db({"id": "alice"})
    with db:
        response = client.get("/users/me", headers=bearer(make_token(roles=())))
    assert response.status_code == 403
    conn.execute.assert_not_called()


def test_roles_from_other_clients_are_ignored():
    token = make_token(roles=(), client_roles={"other-app": {"roles": ["banking-customer"]}})
    assert client.get("/users/me", headers=bearer(token)).status_code == 403


def test_frontend_client_roles_are_accepted():
    token = make_token(roles=(), client_roles={"banking-frontend": {"roles": ["banking-customer"]}})
    db, _ = profile_db({"id": "alice", "full_name": "Alice", "email": "alice@example.test"})
    with db:
        assert client.get("/users/me", headers=bearer(token)).status_code == 200


def test_profile_lookup_uses_only_the_token_user():
    db, conn = profile_db({"id": "alice", "full_name": "Alice", "email": "alice@example.test"})
    with db:
        response = client.get("/users/me?id=bob", headers=bearer(make_token("alice")))
    assert response.status_code == 200
    assert response.json()["id"] == "alice"
    assert conn.execute.call_args.args[1] == {"id": "alice"}


def test_signed_in_user_without_profile_gets_404():
    db, _ = profile_db(None)
    with db:
        assert client.get("/users/me", headers=bearer(make_token("ghost"))).status_code == 404


def test_rejections_are_logged_without_the_token(caplog):
    token = make_token(audience="account")
    with caplog.at_level("WARNING", logger="security.audit"):
        client.get("/users/me", headers=bearer(token))
    assert "authentication_failed" in caplog.text
    assert token not in caplog.text


# ---- registration --------------------------------------------------------------------------

def registration(**overrides):
    return {"id": "Alice", "full_name": "Alice Example", "email": "Alice@Example.com",
            "password": "correct-horse-battery", **overrides}


def test_short_passwords_are_rejected_before_provisioning():
    with patch("app.main.create_keycloak_user") as provision:
        response = client.post("/users", json=registration(password="short"))
    assert response.status_code == 422
    provision.assert_not_called()


def test_registration_normalises_user_id_and_email():
    db, conn = profile_db(None)
    conn.execute.return_value.fetchone.return_value = None  # no existing user with this ID or email
    with db, patch("app.main.create_keycloak_user", return_value=("kc-id", "admin-token")) as provision:
        response = client.post("/users", json=registration())
    assert response.status_code == 200
    assert response.json()["user_id"] == "alice"
    assert provision.call_args.args[0].id == "alice"
    duplicate_check = conn.execute.call_args_list[0].args[1]
    assert duplicate_check == {"id": "alice", "email": "alice@example.com"}
