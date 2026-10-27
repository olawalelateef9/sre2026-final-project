import unittest
from types import SimpleNamespace as NS
from unittest.mock import patch
from fastapi.testclient import TestClient
from agent import run_agent
from main import RateLimiter, app
from auth import fake_user, require_user

class FakeClient:
    def __init__(self, responses):
        self.responses = self
        self.queue = list(responses)
        self.requests = []
    def create(self, **kwargs):
        self.requests.append({**kwargs, "input": list(kwargs["input"])})
        return self.queue.pop(0)

def call(name, arguments="{}"):    
    return NS(type="function_call", name=name, arguments=arguments, call_id="c1")

def response(items, text=""):
    return NS(output=items, output_text=text)

class AgentTests(unittest.TestCase):
    def test_tool_result_is_returned_to_model(self):
        client = FakeClient([response([call("get_balance")]), response([], "Demo balance: £650.")])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "650.00", "mock": True}}, [])):
            result = run_agent("Balance?", client)
        self.assertEqual(result["tool_calls"][0]["result"]["balance"], "650.00")
        self.assertEqual(client.requests[1]["input"][-1]["type"], "function_call_output")
        self.assertTrue(result["mock_data"])
    def test_unknown_tool_is_not_executed(self):
        client = FakeClient([response([call("transfer_money")]), response([], "Cannot transfer.")])
        with patch("agent.get_toolkit", return_value=({}, [])):
            self.assertEqual(run_agent("Transfer", client)["tool_calls"][0]["result"], {"error": "Unknown tool"})
    def test_loop_is_bounded(self):
        client = FakeClient([response([call("get_balance")]) for _ in range(5)])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "0.00"}}, [])):
            with self.assertRaises(RuntimeError):
                run_agent("Balance?", client)
    def test_invalid_arguments(self):
        client = FakeClient([response([call("get_balance", "broken")]), response([], "Retry")])
        with patch("agent.get_toolkit", return_value=({"get_balance": lambda: {"balance": "0.00"}}, [])):
            self.assertEqual(run_agent("Balance?", client)["tool_calls"][0]["result"]["error"], "Invalid tool arguments")
    def test_endpoints_require_auth_and_override_in_tests(self):
        web = TestClient(app)
        # Without token, /chat should be 401
        self.assertEqual(web.post("/chat", json={"message": "Balance?"}).status_code, 401)
        # Override auth dependency for tests
        app.dependency_overrides[require_user] = lambda: fake_user("test-uid")
        try:
            self.assertEqual(web.get("/health").status_code, 200)
            # Validation still applies before auth
            self.assertEqual(web.post("/chat", json={"message": " "}).status_code, 422)
            with patch("main.run_agent", return_value={"answer": "Demo", "tool_calls": [], "mock_data": True}):
                self.assertEqual(web.post("/chat", json={"message": "Balance?"}).json()["answer"], "Demo")
            # /me returns user id from override
            self.assertEqual(web.get("/me").json()["user_id"], "test-uid")
        finally:
            app.dependency_overrides.clear()

    def test_health_does_not_claim_mock_data(self):
        self.assertEqual(TestClient(app).get("/health").json(), {"status": "ok"})

    def test_users_without_assistant_role_are_forbidden(self):
        web = TestClient(app)
        app.dependency_overrides[require_user] = lambda: fake_user("no-ai", roles=("banking-customer",))
        try:
            with patch("main.run_agent") as agent:
                self.assertEqual(web.post("/chat", json={"message": "Balance?"}).status_code, 403)
                self.assertEqual(web.get("/me").status_code, 403)
            agent.assert_not_called()
        finally:
            app.dependency_overrides.clear()

    def test_chat_is_rate_limited_per_user(self):
        web = TestClient(app)
        app.dependency_overrides[require_user] = lambda: fake_user("busy-user")
        try:
            with patch("main.chat_limiter", RateLimiter(2, 60)),                     patch("main.run_agent", return_value={"answer": "ok", "tool_calls": [], "mock_data": False}):
                codes = [web.post("/chat", json={"message": "Balance?"}).status_code for _ in range(3)]
            self.assertEqual(codes, [200, 200, 429])
        finally:
            app.dependency_overrides.clear()

if __name__ == "__main__":
    unittest.main()
