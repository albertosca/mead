# Changelog

## Unreleased

### Added

* Named router slots: besides `local` and `cloud`, `config :mead, :router, slots:` can hold any other slot, such as `gemma: {Mead.Provider.Ollama, model: "gemma2:2b", tool_use: false}`, and `Mead.submit_turn/3` reaches it with `route: :gemma`. `route: :auto` still picks only `local` or `cloud`. A missing named slot fails with `{:slot_unavailable, name}`, and a resumed turn continues on the slot it was recorded on. See [Named slots](https://github.com/albertosca/mead/blob/main/guide/en/router.md#named-slots).
* `Mead.Router.routes/0`, the routes a turn may ask for, read from the config when called.
* The slot option `tool_use: false`, which gives that slot no tools, for models such as Gemma 2 that reject any request carrying tools.
* The `route` enum of the MCP `submit_turn` tool now lists the configured slots, and an unknown route name is refused without becoming an atom.
* Provider option `block_binding: :drop_block | :error` on `Mead.Provider.Anthropic` for preserved-thinking checks (beta header `thinking-binding-controls-2026-08-01`), off by default, and a warning naming the type, reason and path of every `input_transformations` entry a response reports.
* An opt-in test of `Mead.Provider.Anthropic` against the real API (`mix test --include live test/mead/live_anthropic_test.exs`, on `claude-haiku-5-5`): a plain answer, a tool request, a stream, a refused key, and a routed turn through the whole tool loop.

### Changed

* The Anthropic provider keeps the `thinking` and `redacted_thinking` blocks of an answer, verbatim and in order, so the model gets its reasoning back between tool calls; a thinking block without a signature, or an answer with no text and no tool use, is `:malformed_response`. A turn resumed after a crash sends its recorded answers without those blocks, since they were signed against tools and a model the resumed turn may no longer have.
* A request the Anthropic API refuses still returns `{:http_status, status}`, and now also logs a warning with the type and message the API gave (cut to 500 characters), streamed or not, so a 400 for an empty credit balance no longer reads the same as a malformed request.

## 0.3.0 — 2026-11-01

Turns are durable: a turn survives a crash of its session server, a restart of the session pool and a stop of the whole node, and continues where it stopped instead of ending interrupted. See [Durable turns](https://github.com/albertosca/mead/blob/main/guide/en/persistence.md#durable-turns) for the full behaviour.

### Breaking changes

* Every turn handler must implement `resume_turn/4` (`Mead.Session.TurnHandler`), and `Mead.start_session/1` raises `ArgumentError` for a handler without it. The callback gets the history, the input, the steps the turn recorded through the `checkpoint` option, and the options, and continues the turn without redoing those steps.
* On macOS, mead now builds a small native function from `c_src/` and needs a C compiler (`xcode-select --install`, or `CC`). The application refuses to start on macOS when that native code does not load, with `{:native_code_not_loaded, reason}`. Nothing changes on Linux.
* `Mead.submit_turn/3` accepts a `:client_turn_id` option and can return two new errors: `{:error, :invalid_client_turn_id}` and `{:error, {:client_turn_id_conflict, details}}`. A turn submitted without a key gets a generated one (`"mead-<uuid>"`), which shows in the history.

### Migrating from 0.2

* Add `resume_turn/4` to each handler. A handler that records no steps and whose turns are safe to run twice can call `handle_turn/3` again:

  ```elixir
  @impl true
  def resume_turn(history, input, _steps, options), do: handle_turn(history, input, options)
  ```

  When running a turn twice would repeat a side effect (a message sent, a file written), end the cut turn as failed instead:

  ```elixir
  @impl true
  def resume_turn(_history, _input, _steps, _options), do: {:error, :not_resumable}
  ```

* Session files written by 0.2 load as they are. A turn recorded by 0.2 that a crash cuts short ends `interrupted`, because those turns did not keep their options.

### Added

* Idempotent submits: a turn with a `client_turn_id` runs at most once per session. Submitting the same key and input again joins the running turn or returns its outcome; the MCP `submit_turn` tool takes the key too.
* Checkpoints for every step of a routed turn (its route, each model response, each tool call as it starts and as it ends), replayed when the turn continues. An `:effect` tool call that was running when the turn was cut is never run again: the model is told it may or may not have taken effect.
* `Mead.Session.Keeper` resumes, at boot and after a pool restart, the sessions marked under `<storage>/pending/`. An orderly stop suspends running turns, and `Mead.Session.ShutdownGuard` suspends them before the MCP hub stops when a crash takes the tree down.
* `Mead.Watchdog` restarts the root supervisor, with a backoff from 100 ms to 5 s, when it runs out of restarts, and callers keep waiting for their turns through it.
* A deck turn stays alive across a server restart.

### Changed

* Every new file's directory is synced, and on macOS a sync flushes the drive's cache (`F_FULLFSYNC`) instead of only ordering writes.
* A turn whose own session keeps failing is continued at most 3 times; cuts caused by the infrastructure around it count only toward a total of 20.
* Updated bandit to 1.14.1 and websock_adapter to 0.7.0.

## Earlier releases

0.2.1, 0.2.0 and 0.1.1 are tagged in git (`v0.2.1`, `v0.2.0`, `v0.1.1`).
