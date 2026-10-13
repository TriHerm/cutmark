"""The Takes MCP can use Streamable HTTP as well as stdio, for ChatGPT/tunnels (2026-10-13)."""
import http.client
import json
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class HTTPTransportTests(unittest.TestCase):
    def setUp(self):
        self.server = t.http.server.HTTPServer(("127.0.0.1", 0), t.MCPHTTPHandler)
        self.server.takes_token = "test-secret"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def post(self, message, token="test-secret", origin=None, content_type="application/json",
             accept="application/json, text/event-stream", protocol=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        body = json.dumps(message)
        headers = {"Content-Type": content_type, "Accept": accept}
        if protocol and message.get("method") != "initialize":
            headers["MCP-Protocol-Version"] = t.PROTOCOL
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if origin:
            headers["Origin"] = origin
        conn.request("POST", "/mcp", body, headers)
        res = conn.getresponse()
        raw = res.read()
        headers = dict(res.getheaders())
        conn.close()
        value = None
        if raw:
            value = json.loads(raw) if headers.get("Content-Type", "").startswith("application/json") else raw.decode()
        return res.status, headers, value

    def test_initialize_and_tool_list_use_the_same_dispatcher(self):
        status, headers, out = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {"protocolVersion": t.PROTOCOL}})
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual(out["result"]["protocolVersion"], t.PROTOCOL)
        self.assertEqual(out["result"]["serverInfo"]["name"], "cutmark")

        status, _, out = self.post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(status, 200)
        self.assertEqual([x["name"] for x in out["result"]["tools"]],
                         [n for n, *_ in t.TOOLS if t.shown_tool(n)])

    def test_initialize_negotiates_our_supported_version(self):
        status, _, out = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": {"protocolVersion": "2099-01-01"}})
        self.assertEqual(status, 200)
        self.assertEqual(out["result"]["protocolVersion"], t.PROTOCOL)

    def test_initialize_resets_in_memory_rule_state_for_clients_without_a_chat_id(self):
        saved = {k: os.environ.pop(k, None) for k in ("TAKES_CHAT_ID", "CLAUDE_CODE_SESSION_ID")}
        try:
            t.SEEN[None] = {"rules": {"rule-1": "hash"}, "comments": None}
            status, _, _ = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                      "params": {"protocolVersion": t.PROTOCOL}})
            self.assertEqual(status, 200)
            self.assertNotIn(None, t.SEEN)
        finally:
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v

    def test_notifications_get_202_without_a_body(self):
        status, _, out = self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual((status, out), (202, None))

    def test_client_responses_get_202_without_a_body(self):
        status, _, out = self.post({"jsonrpc": "2.0", "id": 7, "result": {}}, protocol=True)
        self.assertEqual((status, out), (202, None))

    def test_bearer_token_is_enforced_when_configured(self):
        status, headers, out = self.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, token=None)
        self.assertEqual(status, 401)
        self.assertEqual(headers["WWW-Authenticate"], "Bearer")
        self.assertEqual(out["error"]["message"], "Unauthorized")

    def test_remote_browser_origin_is_rejected(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        conn.request("POST", "/mcp", body, {"Content-Type": "application/json",
                                             "Accept": "application/json, text/event-stream",
                                             "MCP-Protocol-Version": t.PROTOCOL,
                                             "Authorization": "Bearer test-secret",
                                             "Origin": "https://example.com"})
        res = conn.getresponse()
        raw = res.read().decode()
        conn.close()
        self.assertEqual(res.status, 403)
        self.assertEqual(raw, "Forbidden origin\n")

        for method, path in (("GET", "/"), ("GET", "/mcp"), ("DELETE", "/mcp")):
            conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
            conn.request(method, path, headers={"Origin": "https://example.com"})
            res = conn.getresponse()
            raw = res.read().decode()
            conn.close()
            self.assertEqual(res.status, 403)
            self.assertEqual(raw, "Forbidden origin\n")

    def test_http_contract_headers_are_enforced(self):
        message = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
        status, _, _ = self.post(message, content_type="text/plain")
        self.assertEqual(status, 415)
        status, _, _ = self.post(message, accept="application/json")
        self.assertEqual(status, 406)
        status, _, out = self.post(message, protocol=False)
        self.assertEqual(status, 400)
        self.assertIn("MCP-Protocol-Version", out["error"]["message"])

    def test_non_loopback_requires_a_token(self):
        with self.assertRaisesRegex(ValueError, "CUTMARK_MCP_TOKEN"):
            t.http_main("0.0.0.0", 0, token=None)


if __name__ == "__main__":
    unittest.main()
