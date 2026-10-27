"""Acceptance criteria A4 and A11: real token validation at the FinanceAgent API boundary.

Tokens are signed by a throwaway RSA key served from a local JWKS endpoint, so
the production validation path runs unchanged.
"""
import json
import os
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from jwt.algorithms import RSAAlgorithm

import auth
from main import app

ISSUER = "https://idp.test/realms/banking"
SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
UNTRUSTED_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_JWKS = json.dumps({"keys": [{**json.loads(RSAAlgorithm.to_jwk(SIGNING_KEY.public_key())),
                              "kid": "trusted-key", "use": "sig", "alg": "RS256"}]}).encode()


class _JwksHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(_JWKS)

    def log_message(self, *args):
        pass


def make_token(username="alice", roles=("banking-customer", "banking-ai-agent"), *, issuer=ISSUER,
               audience="banking-api", key=SIGNING_KEY, expires_in=300):
    now = int(time.time())
    claims = {"iss": issuer, "aud": audience, "sub": str(uuid.uuid4()), "iat": now, "exp": now + expires_in,
              "preferred_username": username, "realm_access": {"roles": list(roles)}}
    return jwt.encode({k: v for k, v in claims.items() if v is not None}, key, algorithm="RS256",
                      headers={"kid": "trusted-key"})


class FinanceAgentAuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), _JwksHandler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.env = patch.dict(os.environ, {
            "KEYCLOAK_ISSUER": ISSUER,
            "KEYCLOAK_URL": f"http://127.0.0.1:{cls.server.server_port}",
            "KEYCLOAK_REALM": "banking",
            "KEYCLOAK_AUDIENCE": "banking-api",
        })
        cls.env.start()
        cls._clear_caches()
        cls.web = TestClient(app)

    @classmethod
    def tearDownClass(cls):
        cls.env.stop()
        cls._clear_caches()
        cls.server.shutdown()
        cls.server.server_close()

    @staticmethod
    def _clear_caches():
        for cached in (auth._issuer, auth._jwks_uri, auth._audience, auth._role_client_id,
                       auth.required_roles, auth._jwks_client):
            cached.cache_clear()

    def me(self, token):
        return self.web.get("/me", headers={"Authorization": f"Bearer {token}"})

    def test_valid_token_with_assistant_roles_is_accepted(self):
        response = self.me(make_token("alice"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"user_id": "alice"})

    def test_invalid_tokens_are_rejected(self):
        cases = {
            "expired": make_token(expires_in=-600),
            "untrusted key": make_token(key=UNTRUSTED_KEY),
            "wrong issuer": make_token(issuer="https://evil.test/realms/banking"),
            "wrong audience": make_token(audience="account"),
            "no username": make_token(username=None),
            "unsigned": jwt.encode({"preferred_username": "alice"}, None, algorithm="none"),
            "malformed": "not-a-jwt",
        }
        for name, token in cases.items():
            with self.subTest(name), patch("main.run_agent") as agent:
                self.assertEqual(self.me(token).status_code, 401)
                chat = self.web.post("/chat", json={"message": "Balance?"},
                                     headers={"Authorization": f"Bearer {token}"})
                self.assertEqual(chat.status_code, 401)
                agent.assert_not_called()

    def test_missing_token_is_rejected(self):
        self.assertEqual(self.web.get("/me").status_code, 401)

    def test_customer_without_assistant_role_is_forbidden(self):
        with self.assertLogs("security.audit", "WARNING") as logs:
            token = make_token(roles=("banking-customer",))
            self.assertEqual(self.me(token).status_code, 403)
        self.assertIn("authorization_denied", logs.output[0])
        self.assertNotIn(token, "".join(logs.output))

    def test_rejections_never_log_the_token(self):
        token = make_token(audience="account")
        with self.assertLogs("security.audit", "WARNING") as logs:
            self.me(token)
        self.assertNotIn(token, "".join(logs.output))


if __name__ == "__main__":
    unittest.main()
