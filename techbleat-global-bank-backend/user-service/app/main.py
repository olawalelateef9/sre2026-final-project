import logging
import os

import httpx
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr, Field, SecretStr, field_validator
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.auth import Caller, require_roles

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

DATABASE_URL = os.getenv("DATABASE_URL")
FRONTEND_ORIGIN = os.getenv("FRONTEND_ORIGIN", "http://localhost:3000")
KEYCLOAK_URL = os.getenv("KEYCLOAK_URL", "http://host.docker.internal:8080").rstrip("/")
KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM", "banking")
KEYCLOAK_ADMIN_CLIENT_ID = os.getenv("KEYCLOAK_ADMIN_CLIENT_ID", "banking-provisioner")
KEYCLOAK_ADMIN_CLIENT_SECRET = os.getenv("KEYCLOAK_ADMIN_CLIENT_SECRET", "")

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is required")

engine = create_engine(f"postgresql+psycopg2://{DATABASE_URL.split('://', 1)[1]}")

app = FastAPI(title="Techbleat Global Bank - User Service")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[FRONTEND_ORIGIN],
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


class UserCreate(BaseModel):
    id: str = Field(min_length=3, max_length=50, pattern=r"^[a-zA-Z0-9._-]+$")
    full_name: str = Field(min_length=2, max_length=100)
    email: EmailStr
    password: SecretStr = Field(min_length=12, max_length=128)

    @field_validator("id")
    @classmethod
    def lowercase_id(cls, value: str) -> str:
        # Keycloak lowercases usernames, and APIs match the bank ID to the token's preferred_username.
        return value.lower()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/users")
def create_user(user: UserCreate):
    with engine.begin() as conn:
        existing = conn.execute(
            text("SELECT id FROM users WHERE id = :id OR email = :email"),
            {"id": user.id, "email": str(user.email).lower()},
        ).fetchone()

        if existing:
            raise HTTPException(status_code=400, detail="User ID or email already exists")

    keycloak_user_id, access_token = create_keycloak_user(user)

    try:
        with engine.begin() as conn:
            conn.execute(
                text(
                    '''
                    INSERT INTO users (id, full_name, email)
                    VALUES (:id, :full_name, :email)
                    '''
                ),
                {"id": user.id, "full_name": user.full_name.strip().title(), "email": str(user.email).lower()},
            )

            conn.execute(
                text(
                    '''
                    INSERT INTO accounts (user_id, balance)
                    VALUES (:user_id, 0)
                    '''
                ),
                {"user_id": user.id},
            )
    except IntegrityError as error:
        delete_keycloak_user(keycloak_user_id, access_token)
        raise HTTPException(status_code=409, detail="User ID or email already exists") from error
    except SQLAlchemyError as error:
        delete_keycloak_user(keycloak_user_id, access_token)
        raise HTTPException(status_code=500, detail="Unable to create the bank profile") from error

    return {
        "message": "User and bank account created. Banking access requires administrator role assignment.",
        "user_id": user.id,
    }


def create_keycloak_user(user: UserCreate) -> tuple[str, str]:
    if not KEYCLOAK_ADMIN_CLIENT_SECRET:
        raise HTTPException(status_code=503, detail="Identity provisioning is not configured")

    try:
        token_response = httpx.post(
            f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
            data={
                "grant_type": "client_credentials",
                "client_id": KEYCLOAK_ADMIN_CLIENT_ID,
                "client_secret": KEYCLOAK_ADMIN_CLIENT_SECRET,
            },
            timeout=10,
        )
    except httpx.RequestError as error:
        raise HTTPException(status_code=502, detail="Unable to reach the identity provider") from error

    if token_response.status_code != 200:
        raise HTTPException(status_code=503, detail="Identity provider provisioning credentials are invalid")

    access_token = token_response.json().get("access_token")
    if not access_token:
        raise HTTPException(status_code=502, detail="Identity provider returned no access token")

    first_name, _, last_name = user.full_name.strip().partition(" ")
    headers = {"Authorization": f"Bearer {access_token}"}
    user_url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users"

    try:
        response = httpx.post(
            user_url,
            headers=headers,
            json={
                "username": user.id,
                "email": str(user.email).lower(),
                "firstName": first_name,
                "lastName": last_name,
                "enabled": True,
                "emailVerified": False,
            },
            timeout=10,
        )
    except httpx.RequestError as error:
        raise HTTPException(status_code=502, detail="Unable to create the identity-provider account") from error

    if response.status_code == 409:
        raise HTTPException(status_code=409, detail="Username or email already exists in Keycloak")
    if response.status_code != 201:
        raise HTTPException(status_code=502, detail="Identity provider could not create the account")

    location = response.headers.get("Location", "").rstrip("/")
    keycloak_user_id = location.rsplit("/", 1)[-1] if location else ""
    if not keycloak_user_id:
        raise HTTPException(status_code=502, detail="Identity provider did not return the created account ID")

    try:
        password_response = httpx.put(
            f"{user_url}/{keycloak_user_id}/reset-password",
            headers=headers,
            json={"type": "password", "value": user.password.get_secret_value(), "temporary": True},
            timeout=10,
        )
    except httpx.RequestError as error:
        delete_keycloak_user(keycloak_user_id, access_token)
        raise HTTPException(status_code=502, detail="Unable to set the Keycloak password") from error

    if password_response.status_code != 204:
        delete_keycloak_user(keycloak_user_id, access_token)
        raise HTTPException(status_code=400, detail="Password does not meet Keycloak policy requirements")

    return keycloak_user_id, access_token


def delete_keycloak_user(keycloak_user_id: str, access_token: str) -> None:
    try:
        httpx.delete(
            f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users/{keycloak_user_id}",
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=10,
        )
    except httpx.RequestError:
        pass


@app.get("/users/me")
def current_user(caller: Caller = Depends(require_roles("banking-customer"))):
    with engine.begin() as conn:
        row = conn.execute(
            text(
                '''
                SELECT id, full_name, email, created_at
                FROM users
                WHERE id = :id
                '''
            ),
            {"id": caller.user_id},
        ).mappings().first()
    if row is None:
        raise HTTPException(status_code=404, detail="No bank profile is linked to this sign-in")
    return dict(row)
