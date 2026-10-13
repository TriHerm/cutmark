# ChatGPT direct MCP

Takes can be connected to ChatGPT without routing the request through Codex. The `takes_mcp.py`
process is the MCP server; Codex, Claude Code, pi and the other clients are only possible callers.

ChatGPT custom MCP availability is controlled by the user's plan, workspace policy, and developer-mode
permissions. The server-side integration below is independent of Codex, but the target ChatGPT account
still needs permission to add/use a custom MCP server. OpenAI's current product documentation is the
source of truth for plan availability because that access can change independently of Takes.

## Private Mac: Secure MCP Tunnel

The simplest private setup keeps the Takes server on your Mac and lets OpenAI's tunnel client start
it over stdio. Create a tunnel in OpenAI Platform tunnel settings, then configure the local client
with the `tunnel_id` and control-plane API key from that page:

```sh
export CONTROL_PLANE_API_KEY="sk-..."

tunnel-client init \
  --sample sample_mcp_stdio_local \
  --profile takes-local \
  --tunnel-id tunnel_0123456789abcdef0123456789abcdef \
  --mcp-command "python3 /Applications/Takes.app/Contents/Resources/takes_mcp.py"

tunnel-client doctor --profile takes-local --explain
tunnel-client run --profile takes-local
```

Then in ChatGPT on the web, open **Plugins → + → Add custom MCP server**, choose **Tunnel**, pick
the tunnel, review the permissions, and create the plugin. This path needs no Codex process and does
not expose your local Takes library to a public inbound port.

## Streamable HTTP

The same server can listen on loopback HTTP:

```sh
python3 /Applications/Takes.app/Contents/Resources/takes_mcp.py --http
# http://127.0.0.1:8765/mcp
```

It implements the MCP `2025-06-18` Streamable HTTP request/response contract while keeping stdio as
the default transport. The HTTP listener is deliberately single-threaded for now because several
Takes library helpers still keep small process-global caches. It binds to loopback by default.

Use this endpoint with MCP Inspector or behind a trusted gateway/tunnel. Binding it beyond localhost
requires `TAKES_MCP_TOKEN`, but that fixed bearer token is only a generic transport guard; it is not
a replacement for ChatGPT's OAuth flow on a directly public MCP server.

For a public ChatGPT connection, put Takes behind a stable HTTPS endpoint and implement the auth
model required by that deployment. For a personal/private Takes library, Secure MCP Tunnel is the
preferred route because the local MCP server remains private.

## Existing MCP clients

The original stdio path remains unchanged. `takes_mcp.py --setup` can register Takes with Claude
Code, Codex, Cursor, Gemini CLI, Antigravity, opencode, pi (through pi-mcp-adapter), and Claude
Desktop. Direct ChatGPT access is an additional path; it does not replace those clients.
