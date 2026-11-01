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

### Durable turns

Every turn survives a crash of its session server, a restart of the session pool and a stop of the whole node. A turn submitted without a `client_turn_id` gets a generated one (`"mead-<uuid>"`, shown in the history), and every handler implements `resume_turn/4`: `Mead.start_session/1` refuses one that does not. A handler with nothing to checkpoint resumes by running the turn again.

* Every step of a routed turn is recorded as a checkpoint: its route, each model response, each tool call as it starts and as it ends. A continued turn replays them instead of asking again.
* A `:read` tool call that was running is run again. An `:effect` call that was running is never run again: the model is told it may or may not have taken effect, so it can check before calling it again.
* A session with a turn in progress leaves a marker under `<directory>/pending/`. `Mead.Session.Keeper` resumes those sessions at boot, so the turn continues without anyone asking. An orderly shutdown suspends running turns instead of failing them.
* The call itself waits through a restart of its session server and returns the continued turn's outcome; its caller never sees the crash unless the server does not come back within 5 seconds of it. Submitting again with the same key and input joins the running turn or returns its outcome.
* A turn whose own session keeps failing is continued at most 3 times; after that it ends `interrupted`, so a turn that crashes whatever runs it cannot loop. Cuts caused by a restart of the infrastructure around the session (the pool, the turn supervisor, the registry, or the node) do not count toward those 3, only toward a total of 20.
* A crash of the turn supervisor or of the registry leaves the turn in progress, and it continues once the tree is back. So does a burst of failures past the root supervisor's 10 restarts in 5 seconds: `Mead.Watchdog` starts the root again, with a wait from 100 ms up to 5 seconds, and the caller keeps waiting for its turn.
* An `:effect` call that was cancelled, timed out, lost its connection, got an unreadable answer or crashed while running is reported to the model as one that may or may not have taken effect.
* Every new file's directory is synced, and every deck event is synced before a client is sent it, so a power cut loses no name and reuses no sequence number. On macOS a sync is a real flush of the drive's cache (`F_FULLFSYNC`), not only the ordering barrier Erlang's `:file.sync/1` gives there.
* `Mead.stop_session/1` is final: the running turn ends `interrupted` and is never continued. A turn recorded by an older version, before turns kept their options, also ends `interrupted` after a crash. Resubmitting without a key opens a new turn; pass your own `client_turn_id` to join the one running.

### Compaction and trimming

A file is rewritten as one record per turn on resume, when it passes `compact_after_bytes` (default 1 MiB), and on request through `Mead.compact_session/1`. Compaction keeps every turn unless you set `max_turns`:

```elixir
config :mead, :storage, directory: "/var/lib/mead", max_turns: 200
```

With `max_turns` set, compaction keeps only the newest turns and the older ones are gone. It is off by default because it is the one setting that deletes conversation.

## Ledger

`Mead.Ledger` counts input tokens, output tokens, tool calls and latency per session and per route, plus the last 100 turns. Read it with `Mead.usage/1`, or through the `usage` MCP tool.

It updates ETS in the process that emitted the event and never raises; an event it cannot read is counted as `dropped`. A turn killed by the turn timeout emits no event and is not counted. With a storage directory the ledger is journaled to `ledger.journal` and replayed at boot. It counts tokens, not money: budgets and prices are not part of it.
