🇧🇷 [Português](README.pt.md) · 🇺🇸 [English](README.md)

# mead

Runtime para assistentes baseados em LLM sobre Elixir/OTP: sessões supervisionadas, um router de modelos local/nuvem e cliente e servidor MCP.

Feito por Alberto Cavalcanti · [Conecte no LinkedIn](https://www.linkedin.com/in/albertosca/) · [Docs](https://albertosca.github.io/mead/pt/) · [Arquitetura](docs/ARCHITECTURE.md)

<!-- facts -->890+ testes no CI · gate de cobertura de 93%+ · providers Anthropic e Ollama · cliente e servidor MCP · MIT<!-- /facts -->

[![CI](https://github.com/albertosca/mead/actions/workflows/ci.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![Lint](https://github.com/albertosca/mead/actions/workflows/lint.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/lint.yml) [![Coverage: 93%+](https://img.shields.io/badge/coverage-93%25%2B-brightgreen)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Elixir 1.20+](https://img.shields.io/badge/Elixir-1.20%2B-4B275F.svg)](mix.exs)

## Início rápido

Requer Elixir 1.20+ sobre Erlang/OTP 29.

```
git clone https://github.com/albertosca/mead.git
cd mead
mix deps.get
mix test
```

O handler de turno padrão repete o texto, então uma sessão roda sem chave de API (`iex -S mix`):

```elixir
{:ok, session_id} = Mead.start_session()
Mead.submit_turn(session_id, "hello")
#=> {:ok, "hello"}
```

Para rotear para modelos de verdade, configure os slots do router:

```elixir
config :mead, :turn_handler, Mead.Router

config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.1"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
  ]
```

Persistência, hub e servidor MCP e o endpoint do deck são ligados cada um por sua chave `config :mead`. O [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (em inglês) lista todas as opções.

## Visão geral

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/turn-flow-dark.svg">
  <img alt="Fluxo de um turno: o prompt de um cliente chega a uma sessão supervisionada, o router o envia a um modelo local ou de nuvem, e as chamadas de ferramenta passam pelo hub MCP, que nega por padrão. O log de eventos é gravado antes do envio e o ledger conta cada turno." src="assets/diagrams/turn-flow-light.svg" width="760">
</picture>

- **Sessões.** Um grupo de processos supervisionado por conversa; a falha de um turno fica nessa conversa.
- **Router.** Uma função sem estado que classifica cada turno como local ou nuvem. `route: :local` ou `route: :cloud` sobrescreve.
- **MCP.** Um hub cliente para os servidores que você configurar e um servidor que expõe sessões como nove ferramentas.
- **Ledger.** Tokens, chamadas de ferramenta e latência por sessão e por rota, com journal em disco.

## Garantias

- Um turno local nunca vai para a nuvem; um slot local vazio devolve `:local_unavailable`.
- Ferramentas MCP são negadas a menos que a política permita; no deck, ferramentas `:effect` perguntam à pessoa antes.
- O servidor MCP e o endpoint do deck não sobem sem um bearer token.
- Nada é persistido nem cortado a menos que você configure `storage` e `max_turns`.

## Notas de projeto

| Decisão | Preço |
|---|---|
| Eventos do deck são gravados no log antes de serem enviados | Uma escrita sincronizada por evento; o cliente que reconecta recebe exatamente o que perdeu. |
| O relógio do turno para enquanto um pedido de permissão espera | Uma resposta lenta não derruba o turno; a espera tem limite próprio, `permission_timeout_ms`. |
| O ledger atualiza o ETS no processo que emitiu o evento | Um turno morto por timeout não emite evento e não é contado. |
| O histórico nunca é cortado por padrão | O arquivo da conversa cresce até você definir `max_turns`. |

As decisões, com data, estão no [PROJECT-LOG.md](docs/superpowers/PROJECT-LOG.md).

## Projetos relacionados

`agent-swarm-deck` é o cliente Flutter que fala com o `mead` pelo WebSocket do deck, e `open-butler` guarda a lógica de domínio do assistente. Nenhum dos dois é necessário para rodar o `mead`.

## Contribuir e segurança

Veja o [CONTRIBUTING.md](CONTRIBUTING.md) e o [SECURITY.md](SECURITY.md) para reportar uma vulnerabilidade em privado.

## Licença

MIT © Alberto Cavalcanti
