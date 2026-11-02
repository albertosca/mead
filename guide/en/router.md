# Router and providers

`Mead.Router` is a stateless turn handler: it has no process, so no conversation shares a router with another. For each turn it picks a slot, calls the provider in that slot, and emits a `[:mead, :router, :route]` telemetry event that the ledger counts.

## Choosing a slot

Force a route per turn with `route: :local`, `route: :cloud`, or the name of any other configured slot (see [Named slots](#named-slots)). Without one, a heuristic classifies the turn as local or cloud:

* input over 280 characters, a history over 20 turns, or reasoning words go to the cloud;
* triage and formatting words go to the local model;
* anything else goes to the cloud.

A turn routed to an empty slot fails with `:local_unavailable`, `:cloud_unavailable`, or `{:slot_unavailable, name}` for a named slot. A local turn is never sent to the cloud on its own.

## Named slots

Besides `local` and `cloud`, the router config can hold any other slot, and a turn reaches it by name. This runs Gemma 2 next to the usual local model, chosen per turn:

```elixir
config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.2:3b"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"},
    gemma: {Mead.Provider.Ollama,
            model: "gemma2:2b", keep_alive: "30m", receive_timeout: 60_000, tool_use: false}
  ]
```

```elixir
{:ok, session_id} = Mead.start_session(turn_timeout: 90_000)
Mead.submit_turn(session_id, "Summarise this in one line: ...", route: :gemma)
```

* The valid routes are `:auto`, `:local`, `:cloud` and every other key of `slots`, read when the turn is submitted; `Mead.Router.routes/0` lists them. Any other route gives `{:error, :invalid_route}`. A slot named `auto` is ignored.
* `route: :auto` still chooses only between `local` and `cloud`; a named slot is reached only by asking for it.
* A turn that a crash cut short continues on the slot it was recorded on. If that slot was removed from the config in the meantime, the turn fails with `{:slot_unavailable, name}` instead of moving to another model, and submitting it again with the same `client_turn_id` (directly or over MCP) returns that outcome rather than `:invalid_route`; a new key on the removed slot is refused.
* Over MCP, the `route` property of `submit_turn` lists the same names, and an unknown name is refused without ever becoming an atom.

`tool_use: false` turns the tools off for that slot: its turns are plain completions even when MCP tools are visible. Gemma 2 needs it, because Ollama answers HTTP 400 ("does not support tools") to any request that carries tools, and without the option every turn on that slot fails with `:tools_unsupported` as soon as one tool is configured. Any value other than `true` or `false` fails the turn with `:invalid_slot`.

Gemma 2 2B measured on an 8 GB M1: the first turn after a cold start took 36 seconds (22.6 s loading the model and 11.6 s reading the prompt), above the provider's 25 second receive timeout and the 30 second turn timeout. Hence `keep_alive` to keep the model loaded between turns, `receive_timeout: 60_000` for the first turn, and a session `turn_timeout` of 90 seconds.

## Providers

| Provider | Slot | Notes |
|---|---|---|
| `Mead.Provider.Ollama` | local, or a named slot | Text and tools. Optional `:keep_alive` keeps the model loaded between turns. |
| `Mead.Provider.Anthropic` | cloud | Text, streaming and tools. |

A cold Ollama start can take longer than the provider's 25 second receive timeout, so set `:keep_alive` when the first turn matters.

## Tools

When the chosen provider supports tool calls, its slot does not set `tool_use: false`, and the policy shows at least one tool, the router runs a loop of up to eight provider calls. Tool errors, denials and unknown tools go back to the model as error results and never fail the turn. The loop runs inside the turn timeout, so a conversation that uses tools may need a `:turn_timeout` above the 30 second default.
