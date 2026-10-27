🇺🇸 [English](README.md) · 🇧🇷 [Português](README.pt.md)

# One conversation per process. One model per turn. Nothing runs without your say-so.

`mead` is an Elixir/OTP runtime for AI assistants: it isolates every conversation in its own supervised process, sends each turn to a local or a cloud model, and lets those models use tools over the Model Context Protocol (MCP) only on terms you set.

Built by Alberto Cavalcanti · [Connect on LinkedIn](https://www.linkedin.com/in/albertosca/) · [Quickstart](#quickstart) · [Architecture](docs/ARCHITECTURE.md)

<!-- facts -->890+ tests in CI · 93%+ coverage gate · Anthropic and Ollama providers · MCP client and server · MIT<!-- /facts -->

[![CI](https://github.com/albertosca/mead/actions/workflows/ci.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![Lint](https://github.com/albertosca/mead/actions/workflows/lint.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/lint.yml) [![Coverage: 93%+](https://img.shields.io/badge/coverage-93%25%2B-brightgreen)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Elixir 1.20+](https://img.shields.io/badge/Elixir-1.20%2B-4B275F.svg)](mix.exs)

## How a turn travels

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/turn-flow-dark.svg">
  <img alt="A client sends a prompt to a supervised session. The router classifies it as local or cloud and calls Ollama or Anthropic, looping through the deny-by-default MCP hub when the model asks for a tool. The event log is written before anything is sent, and the ledger counts every turn." src="assets/diagrams/turn-flow-light.svg" width="760">
</picture>

- Each session is a `Mead.Session.Supervisor` under a `DynamicSupervisor`: a timeout, a rate limit or a crashed tool stays inside that turn and does not touch the conversation next to it.
- `Mead.Router` is a stateless function. A short, routine request (status, list, format, triage) goes to the local model; anything long, ambiguous or asking for reasoning goes to the cloud. You can force either with `route: :local` or `route: :cloud`.
- The MCP hub connects to the servers you list, over stdio or HTTP, and exposes only the tools you allow, each classed as `:read` or `:effect`.
- `Mead.Ledger` counts input tokens, output tokens, tool calls and latency per session and per route, in ETS, and survives a restart through a journal.

## What it won't do

- **It never sends a local turn to the cloud on its own.** An empty local slot fails with `:local_unavailable`. A turn you meant to keep on your machine stays there.
- **It never runs a tool you did not allow.** The MCP policy is deny by default, and on the deck a tool classed `:effect` asks the person first unless the policy level is `allow_all`.
- **It never serves without a secret.** The MCP server and the deck endpoint do not start without a bearer token, and a token is never written to a log or an error message.
- **It never keeps a conversation you did not ask it to keep.** Persistence is off until you set `config :mead, :storage, directory:`, and trimming old turns is off until you set `max_turns`.

## Engineering decisions

`mead` holds a person's conversations and can reach their tools, so the bar is: contain every failure to one turn, never act without permission, and never lose what the person was shown. Each decision bought one of those, and the log has the evidence.

| Decision | Trade-off accepted, and the evidence |
|---|---|
| Deny-by-default MCP policy, with a risk class per tool | Every tool needs a line of configuration before the model can see it. |
| The deck event log is written before an event is sent | One synced write per event. In return a client that reconnects replays exactly what it missed, and a crash cannot show a client something the log does not hold. |
| The turn clock stops while a permission request waits | A person who takes two minutes to answer does not make the turn time out. The wait has its own limit, `permission_timeout_ms`. |
| The ledger updates ETS in the process that emitted the event | A handler that raises is detached by `:telemetry`, so it never raises; an event it cannot read is counted as `dropped`. A killed turn emits no event and is not counted, and the docs say so. |
| Compaction keeps every turn unless `max_turns` is set | The conversation file grows without bound by default. Deleting a person's history is the one thing a default must not do. |
| Gates are proven by breaking them | Each guard has a test that fails when the guard is removed. A flaky ledger test was found by reproducing it after a recompile, which showed the test traced the ledger too late; the fix is in [`8288bbc`](https://github.com/albertosca/mead/commit/8288bbc). |

The architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the decisions with their dates are in [docs/superpowers/PROJECT-LOG.md](docs/superpowers/PROJECT-LOG.md).

## Quickstart

You need Elixir 1.20+ on Erlang/OTP 29.

```
git clone https://github.com/albertosca/mead.git
cd mead
mix deps.get
mix test
```

Start a session from `iex -S mix` (the default handler echoes, so this needs no API key):

```elixir
{:ok, session_id} = Mead.start_session()
Mead.submit_turn(session_id, "hello")
#=> {:ok, "hello"}
```

To route real turns, point `Mead.Router` at a model in `config/config.exs`:

```elixir
config :mead, :turn_handler, Mead.Router

config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.1"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
  ]
```

Persistence, the MCP hub and server, and the deck endpoint are each turned on by their own `config :mead` key; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) lists every option.

## Part of a larger system

`mead` is the engine of a personal assistant: `agent-swarm-deck` is the Flutter client that talks to it over the deck WebSocket, and `open-butler` holds the assistant's domain logic. Neither is needed to run `mead`.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## License

MIT © Alberto Cavalcanti
