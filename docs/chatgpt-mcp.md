# ChatGPT direct MCP

Cutmark can connect to ChatGPT without routing requests through Codex. The MCP process is the server; Claude Code, Codex, pi, opencode, Cursor, Gemini CLI, ChatGPT, and other compatible clients are callers.

## Private Mac: Secure MCP Tunnel

For a private laptop or workstation, keep Cutmark's MCP server local and let the Secure MCP Tunnel client start it over stdio. A representative local command is:

```sh
python3 /Applications/Cutmark.app/Contents/Resources/cutmark_mcp.py
```

Configure the tunnel in OpenAI's platform with the tunnel ID and control-plane API key provided there, then use that command as the local MCP command. The exact tunnel-client arguments can change, so use the current OpenAI Secure MCP Tunnel documentation for installation and account-specific setup.

After the tunnel is connected, add the custom MCP server in ChatGPT where custom MCP is enabled for your account or workspace. This path does not require a Codex process and does not expose the Cutmark library on a public inbound port.

## Streamable HTTP

The same MCP implementation can listen on loopback HTTP:

```sh
python3 /Applications/Cutmark.app/Contents/Resources/cutmark_mcp.py --http
# http://127.0.0.1:8765/mcp
```

The current transport implements the MCP `2025-06-18` Streamable HTTP request/response contract while keeping stdio as the default transport. The HTTP listener is deliberately single-threaded because some library helpers still use process-global caches.

Use this endpoint with MCP Inspector or behind a trusted tunnel/gateway. Binding it beyond localhost requires `CUTMARK_MCP_TOKEN`. That fixed bearer token is only a transport guard. It is not a replacement for OAuth on a public MCP service.

For a public ChatGPT deployment, put Cutmark behind a stable HTTPS endpoint and implement appropriate authentication and per-user library isolation. The current HTTP mode is intended for a single-owner local/private deployment.

## Other MCP clients

Cutmark's setup can register the local server with supported MCP clients found on the Mac. Setup registers the local server under the `cutmark` name and only manages that entry.

Starting a new client session may be required after the server is first added because an already-running agent session may not refresh its MCP server list automatically.
