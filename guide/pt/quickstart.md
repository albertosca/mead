# Início rápido

Requer Elixir 1.20+ sobre Erlang/OTP 29. Adicione o mead às dependências no `mix.exs`:

```elixir
def deps do
  [{:mead, "~> 0.1"}]
end
```

Para trabalhar no próprio mead, veja o [CONTRIBUTING.md](https://github.com/albertosca/mead/blob/main/CONTRIBUTING.md).

## Rodar uma sessão

O handler de turno padrão repete a entrada, então não precisa de chave de API. Abra `iex -S mix`:

```elixir
{:ok, session_id} = Mead.start_session()
Mead.submit_turn(session_id, "hello")
#=> {:ok, "hello"}

Mead.history(session_id)
```

## Usar modelos de verdade

Aponte o handler de turno para o router e preencha os dois slots:

```elixir
config :mead, :turn_handler, Mead.Router

config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.1"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
  ]
```

Veja [Router e providers](router.md) para saber como um turno escolhe o slot.
