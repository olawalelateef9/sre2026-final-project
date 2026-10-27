#!/usr/bin/env python3
"""Apply banking-realm.json to a Keycloak server. Safe to run repeatedly.

Creates or updates the realm settings, realm roles, the banking-frontend and
banking-provisioner clients, their scope and audience mappers, and the
provisioner's service-account roles. Anything in the realm that the file does
not describe (other clients, roles, users) is left alone, except that the
scopes and service-account roles of the two managed clients are made to match
the file exactly.

Usage:
    python keycloak/configure_realm.py --dry-run
    python keycloak/configure_realm.py --env-file techbleat-global-bank-backend/.env

Environment:
    KEYCLOAK_URL              Keycloak base URL (default http://localhost:8080)
    KEYCLOAK_ADMIN_USERNAME   master-realm admin user (default admin)
    KEYCLOAK_ADMIN_PASSWORD   prompted for when not set
    FRONTEND_URL              exact frontend origin (default http://localhost:3000)
    KEYCLOAK_SSL_REQUIRED     external (local) or all (deployed); default external
    KEYCLOAK_VERIFY_EMAIL     true once SMTP is configured; default false

Needs only the Python 3.9+ standard library. Secrets are never printed.
"""
import argparse
import getpass
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG_FILE = Path(__file__).with_name("banking-realm.json")
SETTINGS_DEFAULTS = {
    "FRONTEND_URL": "http://localhost:3000",
    "KEYCLOAK_SSL_REQUIRED": "external",
    "KEYCLOAK_VERIFY_EMAIL": "false",
}
# Keys in the config file that drive this script rather than the Keycloak client representation.
CLIENT_EXTRAS = ("realmRoleScope", "clientRoleScope", "serviceAccountClientRoles", "protocolMappers")


class KeycloakAdmin:
    def __init__(self, base_url, realm, dry_run):
        self.base_url = base_url.rstrip("/")
        self.realm = realm
        self.dry_run = dry_run
        self.token = None

    def login(self, username, password):
        body = urllib.parse.urlencode({
            "grant_type": "password", "client_id": "admin-cli", "username": username, "password": password,
        }).encode()
        request = urllib.request.Request(f"{self.base_url}/realms/master/protocol/openid-connect/token", data=body)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                self.token = json.load(response)["access_token"]
        except urllib.error.HTTPError as error:
            sys.exit(f"Admin sign-in failed (HTTP {error.code}). Check the admin username and password.")
        except urllib.error.URLError as error:
            sys.exit(f"Cannot reach Keycloak at {self.base_url}: {error.reason}")

    def call(self, method, path, body=None):
        """Calls the admin API for this realm ('' path = the realm itself). Returns (status, json, headers)."""
        if method != "GET" and self.dry_run:
            return 204, None, {}
        url = f"{self.base_url}/admin/realms/{self.realm}{path}" if path is not None else f"{self.base_url}/admin/realms"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else None, response.headers
        except urllib.error.HTTPError as error:
            if method == "GET" and error.code == 404:
                return 404, None, error.headers
            detail = error.read().decode(errors="replace")[:300]
            sys.exit(f"{method} {url} failed: HTTP {error.code} {detail}")

    def get(self, path):
        return self.call("GET", path)[1]


def load_config(settings):
    text = CONFIG_FILE.read_text(encoding="utf-8")
    missing = sorted(set(re.findall(r"\$\{(\w+)\}", text)) - settings.keys())
    if missing:
        sys.exit(f"No value for {', '.join(missing)}")
    config = json.loads(re.sub(r"\$\{(\w+)\}", lambda match: settings[match.group(1)], text))
    # Realm flags are templated as strings; Keycloak expects booleans.
    for key, value in config["realm"].items():
        if value in ("true", "false"):
            config["realm"][key] = value == "true"
    return config


def validate_settings(settings):
    url = settings["FRONTEND_URL"]
    if not re.fullmatch(r"https?://[^/*\s]+", url):
        sys.exit("FRONTEND_URL must be an exact origin such as https://bank.example.com (no path, slash or wildcard)")
    if settings["KEYCLOAK_SSL_REQUIRED"] not in ("external", "all"):
        sys.exit("KEYCLOAK_SSL_REQUIRED must be external or all")
    if settings["KEYCLOAK_VERIFY_EMAIL"] not in ("true", "false"):
        sys.exit("KEYCLOAK_VERIFY_EMAIL must be true or false")
    if url.startswith("http://") and not re.match(r"http://(localhost|127\.0\.0\.1)(:\d+)?$", url):
        print("WARNING: FRONTEND_URL is plain HTTP on a non-local host; use HTTPS for deployed environments.")


def apply_realm(kc, desired):
    if kc.get("") is None:
        kc.call("POST", None, {"realm": kc.realm, "enabled": True})
        print(f"created realm {kc.realm}")
        if kc.dry_run:
            return False
    current = kc.get("") or {}
    changed = sorted(key for key, value in desired.items() if differs(current.get(key), value))
    if changed:
        kc.call("PUT", "", desired)
        print(f"updated realm settings: {', '.join(changed)}")
    return True


def apply_roles(kc, roles):
    for role in roles:
        path = f"/roles/{urllib.parse.quote(role['name'])}"
        existing = kc.get(path)
        if existing is None:
            kc.call("POST", "/roles", role)
            print(f"created realm role {role['name']}")
        elif existing.get("description") != role.get("description"):
            kc.call("PUT", path, {**existing, **role})
            print(f"updated realm role {role['name']}")


def differs(current, desired):
    """True if any field set in desired has a different value in current (extra fields in current are ignored)."""
    if isinstance(desired, dict):
        return not isinstance(current, dict) or any(differs(current.get(key), value) for key, value in desired.items())
    if isinstance(desired, list) and isinstance(current, list):
        return sorted(map(json.dumps, current)) != sorted(map(json.dumps, desired))
    return current != desired


def find_client(kc, client_id):
    matches = kc.get(f"/clients?clientId={urllib.parse.quote(client_id)}") or []
    return matches[0] if matches else None


def apply_client(kc, desired):
    representation = {key: value for key, value in desired.items() if key not in CLIENT_EXTRAS}
    existing = find_client(kc, desired["clientId"])
    if existing is None:
        kc.call("POST", "/clients", representation)
        print(f"created client {desired['clientId']}")
        existing = find_client(kc, desired["clientId"])
        if existing is None:  # dry run
            return None
    elif differs(existing, representation):
        merged = {**existing, **representation,
                  "attributes": {**existing.get("attributes", {}), **representation.get("attributes", {})}}
        kc.call("PUT", f"/clients/{existing['id']}", merged)
        print(f"updated client {desired['clientId']}")
    return existing["id"]


def apply_mappers(kc, client_uuid, client_id, mappers):
    existing = {mapper["name"]: mapper for mapper in kc.get(f"/clients/{client_uuid}/protocol-mappers/models") or []}
    for mapper in mappers:
        current = existing.get(mapper["name"])
        if current is None:
            kc.call("POST", f"/clients/{client_uuid}/protocol-mappers/models", mapper)
            print(f"created mapper '{mapper['name']}' on {client_id}")
        elif differs(current, mapper):
            kc.call("PUT", f"/clients/{client_uuid}/protocol-mappers/models/{current['id']}", {**mapper, "id": current["id"]})
            print(f"updated mapper '{mapper['name']}' on {client_id}")


def sync_role_mappings(kc, path, available_roles, wanted, label):
    """Makes the role mappings at path exactly match the wanted role names."""
    current = {role["name"]: role for role in kc.get(path) or []}
    missing = [name for name in wanted if name not in current]
    unknown = [name for name in missing if name not in available_roles]
    if unknown:
        sys.exit(f"{label}: roles not found in Keycloak: {', '.join(unknown)}")
    extra = [role for name, role in current.items() if name not in wanted]
    if missing:
        kc.call("POST", path, [available_roles[name] for name in missing])
        print(f"{label}: added {', '.join(missing)}")
    if extra:
        kc.call("DELETE", path, extra)
        print(f"{label}: removed {', '.join(role['name'] for role in extra)}")


def client_roles(kc, client_uuid):
    return {role["name"]: role for role in kc.get(f"/clients/{client_uuid}/roles") or []}


def apply_client_extras(kc, client_uuid, desired):
    client_id = desired["clientId"]
    realm_roles = {role["name"]: role for role in kc.get("/roles") or []}

    sync_role_mappings(kc, f"/clients/{client_uuid}/scope-mappings/realm", realm_roles,
                       desired.get("realmRoleScope", []), f"{client_id} realm-role scope")

    for target_client_id, wanted in desired.get("clientRoleScope", {}).items():
        target = find_client(kc, target_client_id)
        sync_role_mappings(kc, f"/clients/{client_uuid}/scope-mappings/clients/{target['id']}",
                           client_roles(kc, target["id"]), wanted, f"{client_id} {target_client_id} scope")

    apply_mappers(kc, client_uuid, client_id, desired.get("protocolMappers", []))

    for target_client_id, wanted in desired.get("serviceAccountClientRoles", {}).items():
        service_user = kc.get(f"/clients/{client_uuid}/service-account-user")
        target = find_client(kc, target_client_id)
        sync_role_mappings(kc, f"/users/{service_user['id']}/role-mappings/clients/{target['id']}",
                           client_roles(kc, target["id"]), wanted, f"{client_id} service account {target_client_id} roles")


def write_secret(kc, client_uuid, env_file):
    secret = kc.get(f"/clients/{client_uuid}/client-secret")["value"]
    path = Path(env_file)
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    entry = f"KEYCLOAK_ADMIN_CLIENT_SECRET={secret}"
    if entry in lines:
        print(f"{env_file}: KEYCLOAK_ADMIN_CLIENT_SECRET already current")
        return
    lines = [line for line in lines if not line.startswith("KEYCLOAK_ADMIN_CLIENT_SECRET=")] + [entry]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{env_file}: wrote KEYCLOAK_ADMIN_CLIENT_SECRET (value not shown)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true", help="read the realm and report changes without writing")
    parser.add_argument("--env-file", help="write the banking-provisioner secret into this (git-ignored) .env file")
    args = parser.parse_args()

    settings = {name: os.getenv(name, default) for name, default in SETTINGS_DEFAULTS.items()}
    validate_settings(settings)
    config = load_config(settings)

    kc = KeycloakAdmin(os.getenv("KEYCLOAK_URL", "http://localhost:8080"), config["realm"]["realm"], args.dry_run)
    username = os.getenv("KEYCLOAK_ADMIN_USERNAME", "admin")
    password = os.getenv("KEYCLOAK_ADMIN_PASSWORD") or getpass.getpass(f"Keycloak admin password for '{username}': ")
    kc.login(username, password)

    print(f"{'DRY RUN: ' if args.dry_run else ''}configuring realm '{kc.realm}' at {kc.base_url} "
          f"for frontend {settings['FRONTEND_URL']}")
    if not apply_realm(kc, config["realm"]):
        print("Realm does not exist yet; run without --dry-run to create it.")
        return
    apply_roles(kc, config["roles"])
    for client in config["clients"]:
        client_uuid = apply_client(kc, client)
        if client_uuid:
            apply_client_extras(kc, client_uuid, client)
            if client["clientId"] == "banking-provisioner" and args.env_file and not args.dry_run:
                write_secret(kc, client_uuid, args.env_file)
    print("Dry run complete; nothing was changed." if args.dry_run else "Done.")


if __name__ == "__main__":
    main()
