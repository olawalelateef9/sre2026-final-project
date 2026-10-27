"""Authenticated, read-only banking tools for FinanceAgent."""
from __future__ import annotations

import os
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Dict, Literal, Tuple
from urllib.parse import quote

import httpx
from fastapi import HTTPException, status

from auth import user_from_token


MAX_TRANSACTIONS = 20
OUTGOING_TYPES = {"WITHDRAW", "TRANSFER_OUT"}


def _model_safe_transaction(tx: Any) -> Dict[str, Any]:
    """Keeps only type, signed amount and date.

    References are free text that other customers can write (a transfer's
    reference reaches the recipient), so they are a prompt-injection channel and
    may name other customers; account and record IDs are not needed either.
    """
    if not isinstance(tx, dict):
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API returned invalid transactions")
    tx_type = str(tx.get("transactionType", "UNKNOWN"))
    try:
        amount = Decimal(str(tx.get("amount")))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API returned an invalid amount") from exc
    if tx_type in OUTGOING_TYPES:
        amount = -abs(amount)
    return {"type": tx_type, "amount": f"{amount:.2f}", "date": str(tx.get("createdAt", ""))[:10]}


def _tx_base() -> str:
    return os.getenv("TRANSACTION_API_URL", "").rstrip("/")


def _authorized_user(context: Dict[str, Any]) -> tuple[str, str]:
    token = context.get("token")
    if not isinstance(token, str) or not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="A valid bearer token is required for banking tools")

    user = user_from_token(token)
    if context.get("user_id") != user.user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail="Tool user does not match the authenticated token")
    return user.user_id, token


def _get_from_backend(context: Dict[str, Any], resource: Literal["balance", "transactions"]) -> tuple[str, Any]:
    user_id, token = _authorized_user(context)
    base = _tx_base()
    if not base:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail="Transaction API is not configured")

    try:
        with httpx.Client(timeout=5.0) as http:
            response = http.get(
                f"{base}/{resource}/{quote(user_id, safe='')}",
                headers={"Authorization": f"Bearer {token}"},
            )
            response.raise_for_status()
            return user_id, response.json()
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                            detail="Transaction API timed out") from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API rejected the request") from exc
    except httpx.RequestError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Unable to reach the transaction API") from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                            detail="Transaction API returned invalid JSON") from exc


def get_toolkit(context: Dict[str, Any] | None = None) -> Tuple[Dict[str, Callable[..., Any]], list[dict]]:
    ctx = context or {}

    def get_balance() -> Dict[str, Any]:
        user_id, data = _get_from_backend(ctx, "balance")
        if not isinstance(data, dict) or data.get("balance") is None:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned no balance")
        try:
            balance = f"{Decimal(str(data['balance'])):.2f}"
        except (InvalidOperation, TypeError, ValueError) as exc:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned an invalid balance") from exc
        return {"account_id": user_id, "currency": "GBP", "balance": balance, "mock": False}

    def get_recent_transactions() -> Dict[str, Any]:
        _, transactions = _get_from_backend(ctx, "transactions")
        if not isinstance(transactions, list):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY,
                                detail="Transaction API returned invalid transactions")
        recent = [_model_safe_transaction(tx) for tx in transactions[:MAX_TRANSACTIONS]]
        return {"currency": "GBP", "mock": False, "transactions": recent}

    tool_functions: Dict[str, Callable[..., Any]] = {
        "get_balance": get_balance,
        "get_recent_transactions": get_recent_transactions,
    }

    tool_schemas = [
        {"type": "function", "name": name, "description": description,
         "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
         "strict": True}
        for name, description in [
            ("get_balance", "Get the authenticated user's current account balance in GBP."),
            ("get_recent_transactions", "Get the authenticated user's 20 most recent transactions (type, amount, date). Negative amounts are money leaving the account."),
        ]
    ]

    return tool_functions, tool_schemas
