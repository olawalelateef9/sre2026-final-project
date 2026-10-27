"""Acceptance criteria A4 (token rejection) and A5 (no cross-account access) for the activity service."""
from unittest.mock import MagicMock, patch

import jwt
import pytest
from fastapi.testclient import TestClient

from conftest import UNTRUSTED_KEY, bearer, make_token
from app.main import app

# Not used as a context manager, so the Kafka consumer startup hook does not run.
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


def activity_db(rows):
    """Patches the engine so the activity query returns rows; returns the patcher and mock connection."""
    conn = MagicMock()
    conn.execute.return_value.mappings.return_value.all.return_value = rows
    engine = MagicMock()
    engine.begin.return_value.__enter__.return_value = conn
    return patch("app.main.engine", engine), conn


def test_health_is_public():
    assert client.get("/health").status_code == 200


def test_missing_token_is_rejected():
    assert client.get("/activities/alice").status_code == 401


@pytest.mark.parametrize("case", INVALID_TOKENS)
def test_invalid_tokens_are_rejected(case):
    db, conn = activity_db([])
    with db:
        response = client.get("/activities/alice", headers=bearer(INVALID_TOKENS[case]()))
    assert response.status_code == 401
    conn.execute.assert_not_called()


def test_token_without_customer_role_is_forbidden():
    db, conn = activity_db([])
    with db:
        response = client.get("/activities/alice", headers=bearer(make_token("alice", roles=())))
    assert response.status_code == 403
    conn.execute.assert_not_called()


def test_owner_can_read_own_activity():
    db, conn = activity_db([{"id": 1, "user_id": "alice", "activity_type": "DEPOSIT"}])
    with db:
        response = client.get("/activities/alice", headers=bearer(make_token("alice")))
    assert response.status_code == 200
    assert conn.execute.call_args.args[1] == {"user_id": "alice"}


def test_cannot_read_another_customers_activity(caplog):
    db, conn = activity_db([{"id": 1, "user_id": "bob"}])
    token = make_token("alice")
    with db, caplog.at_level("WARNING", logger="security.audit"):
        response = client.get("/activities/bob", headers=bearer(token))
    assert response.status_code == 403
    conn.execute.assert_not_called()
    assert "authorization_denied" in caplog.text and "user=alice" in caplog.text
    assert token not in caplog.text
