# Quickstart

Requires Elixir 1.20+ on Erlang/OTP 29. Add mead to your dependencies in `mix.exs`:

```elixir
def deps do
  [{:mead, "~> 0.1"}]
end
```

To work on mead itself, see [CONTRIBUTING.md](https://github.com/albertosca/mead/blob/main/CONTRIBUTING.md).

## Run a session

The default turn handler echoes the input, so this needs no API key. Start `iex -S mix`:

```elixir
{:ok, session_id} = Mead.start_session()
Mead.submit_turn(session_id, "hello")
#=> {:ok, "hello"}

Mead.history(session_id)
```

## Use real models

Point the turn handler at the router and fill the two slots:

```elixir
config :mead, :turn_handler, Mead.Router

config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.1"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
  ]
```

See [Router and providers](router.md) for how a turn picks its slot.
