# FinanceAgent: very basic banking agent

Python 3.10+ recommended. A tiny FastAPI service with two read-only tools, no
agent framework, no database and no conversation memory. The API requires a
Keycloak bearer token for `/me` and `/chat`. Each banking tool revalidates the
token and uses the token's `preferred_username` claim as the bank profile ID.
Tools fail closed if the token is invalid or the backend is unavailable; they
do not return mock customer data.

## Authentication

The service verifies the token signature using the configured Keycloak realm
JWKS and checks the issuer and audience against configuration. In Docker Compose,
the defaults match the local banking realm token (`http://localhost:8080/realms/banking`,
audience `banking-api`, shared with the transaction service, which receives the
forwarded token); `KEYCLOAK_URL` uses `host.docker.internal` so the container
can fetch JWKS from Keycloak running on the host. Override `KEYCLOAK_ISSUER` and
`KEYCLOAK_AUDIENCE` if your access tokens use different claims. `/health` is
public.

## Start (macOS / Linux)

```bash
cd finance-agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Edit `.env` and supply your OpenAI API key. Model is configurable; use a model
your account can access that supports Responses API function calling.
OpenAI API usage requires API billing; a ChatGPT subscription does not supply
an API key or API credits. Keep `.env` private.

```bash
uvicorn main:app --reload --host 127.0.0.1 --port 9001
```

Open http://localhost:9001/docs. Expand **POST /chat**, click **Try it out**,
and enter:

```json
{"message": "Can I afford to spend £200?"}
```

Or use a terminal:

```bash
curl http://localhost:9001/health
curl -X POST http://localhost:9001/chat \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"message":"What is my balance, and can I afford to spend £200?"}'
```

The response contains `answer`, `tool_calls` (tool names and results) and
`mock_data: false` when the backend returned real data. Wording and tool
choices come from the model and can vary. You can also ask "Show my recent
transactions".

## How the code works

1. `main.py` receives the question at `/chat`.
2. `agent.py` sends the question and tool definitions to the model.
3. The model requests a tool. Python executes only an allowlisted function.
4. Python sends the tool result back to the model.
5. The model writes the answer. At most five model calls are allowed.

`tools.py` holds the authenticated backend calls and tool schemas. The AI does
not call Python directly: the loop interprets its structured requests and
executes them. Each question starts fresh. Example: asking "What about £300?"
after a previous question does not retain that question's context.

## Next step: your Banking app

The agent calls the balance and transaction endpoints using the identity in
the verified token. Do not let model-supplied data select a customer. The
transaction service should also validate bearer tokens and enforce account
ownership before being exposed beyond this trusted local Compose network. This
agent has no transfer or payment capability.

## Verify without API charges

```bash
python -m unittest discover -s tests -v
```

Tests use a fake model client to verify the loop and API validation. They do not
call OpenAI. Live model behavior requires your API key and has not been verified
by these tests.

Troubleshooting: 503 means the key is missing; 502 indicates a model/API failure
or loop limit; 422 indicates an invalid/empty request. `/health` only checks the
web service, not model connectivity.

Official function-calling reference:
https://developers.openai.com/api/docs/guides/function-calling
