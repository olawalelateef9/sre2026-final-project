#!/usr/bin/env python3
"""Create the demo customers for a session. Safe to rerun.

Each user is registered through the application's public registration API (the same
path a customer takes), then made ready through the Keycloak admin API: a permanent
password, the banking-customer and banking-transact roles, no first-login actions.
Data is synthetic; passwords come from the environment and are never printed.

Environment:
    APP_URL                    public app URL, e.g. https://techbleatglobalbank.duckdns.org
    KEYCLOAK_URL               admin API URL (a port-forward, e.g. http://localhost:18080)
    KEYCLOAK_ADMIN_USERNAME / KEYCLOAK_ADMIN_PASSWORD
    DEMO_USERS                 JSON list of {"id", "full_name", "email", "password"}

Needs only the Python standard library.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from configure_realm import KeycloakAdmin  # noqa: E402

REALM = "banking"
ROLES = ["banking-customer", "banking-transact"]


def register(app_url, user):
    """POST /user-api/users; an existing user (400/409) is fine."""
    body = json.dumps({key: user[key] for key in ("id", "full_name", "email", "password")}).encode()
    request = urllib.request.Request(f"{app_url}/user-api/users", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30):
            return "registered"
    except urllib.error.HTTPError as error:
        if error.code in (400, 409):
            return "already registered"
        sys.exit(f"Registering {user['id']} failed: HTTP {error.code} {error.read().decode(errors='replace')[:200]}")


def make_ready(kc, user, newly_registered):
    matches = kc.get(f"/users?username={urllib.parse.quote(user['id'])}&exact=true") or []
    if not matches:
        sys.exit(f"{user['id']} is not in Keycloak after registration")
    user_id = matches[0]["id"]

    # Registration already set this password; setting it again would break the realm's
    # password-history policy. Existing users (a rerun) get the new session password.
    if not newly_registered:
        kc.call("PUT", f"/users/{user_id}/reset-password",
                {"type": "password", "value": user["password"], "temporary": False})
    # A "temporary" password is just the UPDATE_PASSWORD required action; clearing it makes
    # the password usable without a forced change at first sign-in.
    kc.call("PUT", f"/users/{user_id}", {**matches[0], "emailVerified": True, "requiredActions": []})

    available = {role["name"]: role for role in kc.get("/roles") or []}
    current = {role["name"] for role in kc.get(f"/users/{user_id}/role-mappings/realm") or []}
    missing = [available[name] for name in ROLES if name not in current]
    if missing:
        kc.call("POST", f"/users/{user_id}/role-mappings/realm", missing)


def main():
    app_url = os.environ["APP_URL"].rstrip("/")
    users = json.loads(os.environ["DEMO_USERS"])

    kc = KeycloakAdmin(os.environ.get("KEYCLOAK_URL", "http://localhost:18080"), REALM, dry_run=False)
    kc.login(os.environ["KEYCLOAK_ADMIN_USERNAME"], os.environ["KEYCLOAK_ADMIN_PASSWORD"])

    for user in users:
        outcome = register(app_url, user)
        make_ready(kc, user, newly_registered=(outcome == "registered"))
        print(f"{user['id']}: {outcome}, roles {', '.join(ROLES)}, password set")


if __name__ == "__main__":
    main()
