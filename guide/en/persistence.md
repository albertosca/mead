# Persistence and ledger

## Persistence

Persistence is off by default. Turn it on with a directory:

```elixir
config :mead, :storage, directory: "/var/lib/mead"
```

Each session is one append-only file named after its id, with a checksum on every record. `Mead.stop_session/1` keeps the file, `Mead.resume_session/2` rebuilds the session from it, and `Mead.delete_session/1` removes it.

* A turn that cannot be recorded is refused before the handler starts, so a conversation never accepts a turn it would forget.
* A record cut short at the end of the file, which is what a crash leaves, is dropped with a warning. Damage anywhere else is `{:error, :corrupt_history}`.
* The files are private (mode 0600). The directory must be trusted and have a single writer.

### Compaction and trimming

A file is rewritten as one record per turn on resume, when it passes `compact_after_bytes` (default 1 MiB), and on request through `Mead.compact_session/1`. Compaction keeps every turn unless you set `max_turns`:

```elixir
config :mead, :storage, directory: "/var/lib/mead", max_turns: 200
```

With `max_turns` set, compaction keeps only the newest turns and the older ones are gone. It is off by default because it is the one setting that deletes conversation.

## Ledger

`Mead.Ledger` counts input tokens, output tokens, tool calls and latency per session and per route, plus the last 100 turns. Read it with `Mead.usage/1`, or through the `usage` MCP tool.

It updates ETS in the process that emitted the event and never raises; an event it cannot read is counted as `dropped`. A turn killed by the turn timeout emits no event and is not counted. With a storage directory the ledger is journaled to `ledger.journal` and replayed at boot. It counts tokens, not money: budgets and prices are not part of it.
