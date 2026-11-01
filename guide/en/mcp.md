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

`submit_turn` takes an optional `client_turn_id`. Send the same id again after a lost connection: the turn runs once, and the retry waits for it or gets its stored answer. If the session restarts while a keyed turn runs, the call waits for it to come back and answers with the turn's own outcome: its result, or that it was interrupted once its resume budget ran out. A turn submitted without a `client_turn_id` gets a generated one and continues the same way, but a retry without a key starts a new turn. Only when the session does not come back within 5 seconds of a crash does the call fail, with a message saying so; the turn still continues once it does, and submitting again with the same `client_turn_id` returns its outcome.

Add `certfile` and `keyfile` to serve HTTPS. The full list of limits and status codes is in [ARCHITECTURE.md](https://github.com/albertosca/mead/blob/main/docs/ARCHITECTURE.md).
