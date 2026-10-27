"""Test tokens signed by a throwaway RSA key, served from a local JWKS endpoint.

The production validation path (JWKS fetch, signature, expiry, issuer, audience)
runs unchanged. Environment is set before the app is imported.
"""
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

ISSUER = "https://idp.test/realms/banking"
AUDIENCE = "banking-api"
KEY_ID = "trusted-key"

SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
UNTRUSTED_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

_jwk = json.loads(RSAAlgorithm.to_jwk(SIGNING_KEY.public_key()))
_jwks_body = json.dumps({"keys": [{**_jwk, "kid": KEY_ID, "use": "sig", "alg": "RS256"}]}).encode()


class _JwksHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(_jwks_body)

    def log_message(self, *args):
        pass


_server = HTTPServer(("127.0.0.1", 0), _JwksHandler)
threading.Thread(target=_server.serve_forever, daemon=True).start()

os.environ.update({
    "DATABASE_URL": "postgresql://test:test@127.0.0.1:1/test",
    "KEYCLOAK_ISSUER": ISSUER,
    "KEYCLOAK_JWK_SET_URI": f"http://127.0.0.1:{_server.server_port}/certs",
    "KEYCLOAK_AUDIENCE": AUDIENCE,
    "KEYCLOAK_ROLE_CLIENT_ID": "banking-frontend",
})


def make_token(username="alice", roles=("banking-customer",), *, issuer=ISSUER, audience=AUDIENCE,
               key=SIGNING_KEY, expires_in=300, client_roles=None, **extra_claims):
    now = int(time.time())
    claims = {
        "iss": issuer,
        "aud": audience,
        "sub": str(uuid.uuid4()),
        "iat": now,
        "exp": now + expires_in,
        "preferred_username": username,
        "realm_access": {"roles": list(roles)},
        **({"resource_access": client_roles} if client_roles else {}),
        **extra_claims,
    }
    claims = {name: value for name, value in claims.items() if value is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": KEY_ID})


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def token():
    return make_token
