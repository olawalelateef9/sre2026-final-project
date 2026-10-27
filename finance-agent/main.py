"""Start with: uvicorn main:app --reload --port 9001"""
import logging
import os
import threading
import time
from collections import defaultdict, deque
from dotenv import load_dotenv
load_dotenv()
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator
from openai import OpenAIError
from agent import run_agent
from auth import require_agent_user, UserContext

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger("finance-agent")

app = FastAPI(title="FinanceAgent — basic banking demo")


class RateLimiter:
    """Sliding-window limit per user. In-memory, so each replica counts separately."""

    def __init__(self, limit: int, window_seconds: float):
        self.limit = limit
        self.window = window_seconds
        self._calls = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            calls = self._calls[key]
            while calls and now - calls[0] >= self.window:
                calls.popleft()
            if len(calls) >= self.limit:
                return False
            calls.append(now)
            return True


chat_limiter = RateLimiter(int(os.getenv("FINANCE_AGENT_RATE_LIMIT_PER_MINUTE", "10")), 60)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)

    @field_validator("message")
    @classmethod
    def nonempty(cls, value):
        value = value.strip()
        if not value:
            raise ValueError("Message cannot be blank")
        return value

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/me")
def me(user: UserContext = Depends(require_agent_user)):
    return {"user_id": user.user_id}

@app.post("/chat")
def chat(request: ChatRequest, user: UserContext = Depends(require_agent_user)):
    if not chat_limiter.allow(user.user_id):
        logger.warning("chat_rate_limited user=%s", user.user_id)
        raise HTTPException(status_code=429, detail="Too many questions. Please wait a minute and try again.",
                            headers={"Retry-After": "60"})
    try:
        # Pass user context to tools so they can call backend APIs
        result = run_agent(request.message, tool_context={"user_id": user.user_id, "token": user.get("token")})
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except OpenAIError as exc:
        logger.warning("Model API request failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Model API request failed. Check your API key, model access, billing and connectivity.") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    # Record which tools ran, never the question, answer or tool data.
    logger.info("chat_completed user=%s tools=%s", user.user_id, ",".join(c["tool"] for c in result["tool_calls"]) or "none")
    return result
