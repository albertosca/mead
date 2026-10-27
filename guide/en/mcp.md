# MCP

`mead` is both sides of the Model Context Protocol.

## Hub: give models tools

`config :mead, :mcp, servers: [...]` lists the MCP servers. Each has a transport, `{:stdio, command:, arguments:}` or `{:http, url:, headers:}`, and the tools you allow, each declared as `:read` or `:effect`.

```elixir
config :mead, :mcp,
  servers: [
    # one entry per server: a transport and the tools you allow, each as :read or :effect
  ]
```

* The policy is deny by default. A tool the server offers and the configuration does not list does not exist for the model.
* `:read` tools are always shown. `:effect` tools are shown only when the turn passes `tools: :effect`.
* The class comes from your configuration, never from the server.
* A connection that fails is retried after 1, 2, 5, 15, then 30 seconds, and never crashes the application.

## Server: drive mead from another client

`config :mead, :mcp_server, token: "...", port: 4040` starts an HTTP listener on `POST /mcp`. Without a `token` nothing listens. Requests need a bearer token, and the `Origin` header is checked.

It exposes nine tools: `start_session`, `submit_turn`, `history`, `stop_session`, `resume_session`, `delete_session`, `list_sessions`, `compact_session` and `usage`. `tools: "effect"` is honoured only when the operator set `allow_effect: true`.

Add `certfile` and `keyfile` to serve HTTPS. The full list of limits and status codes is in [ARCHITECTURE.md](https://github.com/albertosca/mead/blob/main/docs/ARCHITECTURE.md).
