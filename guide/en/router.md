# Router and providers

`Mead.Router` is a stateless turn handler: it has no process, so no conversation shares a router with another. For each turn it picks a slot, calls the provider in that slot, and emits a `[:mead, :router, :route]` telemetry event that the ledger counts.

## Choosing a slot

Force a route per turn with `route: :local` or `route: :cloud`. Without one, a heuristic classifies the turn:

* input over 280 characters, a history over 20 turns, or reasoning words go to the cloud;
* triage and formatting words go to the local model;
* anything else goes to the cloud.

A turn routed to an empty slot fails with `:local_unavailable` or `:cloud_unavailable`. A local turn is never sent to the cloud on its own.

## Providers

| Provider | Slot | Notes |
|---|---|---|
| `Mead.Provider.Ollama` | local | Text and tools. Optional `:keep_alive` keeps the model loaded between turns. |
| `Mead.Provider.Anthropic` | cloud | Text, streaming and tools. |

A cold Ollama start can take longer than the provider's 25 second receive timeout, so set `:keep_alive` when the first turn matters.

## Tools

When the chosen provider supports tool calls and the policy shows at least one tool, the router runs a loop of up to eight provider calls. Tool errors, denials and unknown tools go back to the model as error results and never fail the turn. The loop runs inside the turn timeout, so a conversation that uses tools may need a `:turn_timeout` above the 30 second default.
