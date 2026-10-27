# mead

Runtime for LLM-backed assistants on Elixir/OTP: supervised sessions, a local/cloud model router, and an MCP client and server.

## What it provides

* **Sessions.** One supervised process pair per conversation: a history and a server. A crash is contained to the conversation, and a turn that was running comes back marked `interrupted`.
* **Router.** A stateless function that sends each turn to a local model (Ollama) or a cloud model (Anthropic).
* **MCP.** A hub that connects to the MCP servers you configure, and a server that exposes sessions to other clients.
* **Persistence.** One append-only file per conversation, so a stopped session can be resumed.
* **Ledger.** Tokens, tool calls and latency per session and per route.

## Where to go next

* [Quickstart](quickstart.md) to run a session.
* [Router and providers](router.md) to send turns to real models.
* [MCP](mcp.md) to give models tools, or to drive `mead` from another client.
* [Persistence and ledger](persistence.md) to keep conversations and count usage.
