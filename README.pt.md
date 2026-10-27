🇧🇷 [Português](README.pt.md) · 🇺🇸 [English](README.md)

# Uma conversa por processo. Um modelo por turno. Nada roda sem a sua licença.

O `mead` é um runtime Elixir/OTP para assistentes de IA: isola cada conversa num processo supervisionado, manda cada turno para um modelo local ou de nuvem, e deixa esses modelos usarem ferramentas pelo Model Context Protocol (MCP) só nos termos que você define.

Feito por Alberto Cavalcanti · [Conecte no LinkedIn](https://www.linkedin.com/in/albertosca/) · [Início rápido](#início-rápido) · [Arquitetura](docs/ARCHITECTURE.md)

<!-- facts -->890+ testes no CI · gate de cobertura de 93%+ · providers Anthropic e Ollama · cliente e servidor MCP · MIT<!-- /facts -->

[![CI](https://github.com/albertosca/mead/actions/workflows/ci.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![Lint](https://github.com/albertosca/mead/actions/workflows/lint.yml/badge.svg)](https://github.com/albertosca/mead/actions/workflows/lint.yml) [![Coverage: 93%+](https://img.shields.io/badge/coverage-93%25%2B-brightgreen)](https://github.com/albertosca/mead/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Elixir 1.20+](https://img.shields.io/badge/Elixir-1.20%2B-4B275F.svg)](mix.exs)

## Como um turno viaja

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/turn-flow-dark.svg">
  <img alt="Um cliente envia um prompt a uma sessão supervisionada. O router o classifica como local ou nuvem e chama Ollama ou Anthropic, passando pelo hub MCP, que nega por padrão, quando o modelo pede uma ferramenta. O log de eventos é gravado antes de qualquer envio, e o ledger conta cada turno." src="assets/diagrams/turn-flow-light.svg" width="760">
</picture>

- Cada sessão é um `Mead.Session.Supervisor` sob um `DynamicSupervisor`: um timeout, um rate limit ou uma ferramenta que cai fica dentro daquele turno e não encosta na conversa do lado.
- O `Mead.Router` é uma função sem estado. Um pedido curto e de rotina (status, listar, formatar, triagem) vai para o modelo local; o que for longo, ambíguo ou pedir raciocínio vai para a nuvem. Dá para forçar um dos dois com `route: :local` ou `route: :cloud`.
- O hub MCP conecta nos servidores que você listar, por stdio ou HTTP, e expõe só as ferramentas que você permitir, cada uma classificada como `:read` ou `:effect`.
- O `Mead.Ledger` conta tokens de entrada, tokens de saída, chamadas de ferramenta e latência por sessão e por rota, em ETS, e sobrevive a um restart por meio de um journal.

## O que ele não faz

- **Nunca manda um turno local para a nuvem por conta própria.** Um slot local vazio falha com `:local_unavailable`. O turno que você quis manter na sua máquina fica nela.
- **Nunca roda uma ferramenta que você não permitiu.** A política MCP nega por padrão, e no deck uma ferramenta `:effect` pergunta à pessoa antes, a menos que o nível seja `allow_all`.
- **Nunca atende sem um segredo.** O servidor MCP e o endpoint do deck não sobem sem um bearer token, e o token nunca vai para um log nem para uma mensagem de erro.
- **Nunca guarda uma conversa que você não pediu para guardar.** A persistência fica desligada até você definir `config :mead, :storage, directory:`, e o corte de turnos antigos fica desligado até você definir `max_turns`.

## Decisões de engenharia

O `mead` guarda as conversas de uma pessoa e alcança as ferramentas dela, então o critério é: conter toda falha dentro de um turno, nunca agir sem permissão e nunca perder o que a pessoa viu. Cada decisão abaixo comprou uma dessas, e o log tem a evidência.

| Decisão | Preço aceito, e a evidência |
|---|---|
| Política MCP que nega por padrão, com classe de risco por ferramenta | Toda ferramenta precisa de uma linha de configuração antes de o modelo enxergá-la. |
| O log de eventos do deck é gravado antes de o evento ser enviado | Uma escrita sincronizada por evento. Em troca, um cliente que reconecta recebe exatamente o que perdeu, e uma queda não mostra a um cliente algo que o log não tem. |
| O relógio do turno para enquanto um pedido de permissão espera | Quem demora dois minutos para responder não derruba o turno por timeout. A espera tem limite próprio, `permission_timeout_ms`. |
| O ledger atualiza o ETS no processo que emitiu o evento | Um handler que levanta erro é desanexado pelo `:telemetry`, então ele nunca levanta; um evento ilegível é contado como `dropped`. Um turno morto não emite evento e não é contado, e a documentação diz isso. |
| A compactação guarda todos os turnos, a menos que `max_turns` esteja definido | O arquivo da conversa cresce sem limite por padrão. Apagar o histórico de uma pessoa é a única coisa que um padrão não pode fazer. |
| Os gates são provados quebrando-os | Cada guarda tem um teste que falha quando a guarda sai. Um teste instável do ledger foi achado reproduzindo-o depois de uma recompilação, o que mostrou que o teste rastreava o ledger tarde demais; o conserto está em [`8288bbc`](https://github.com/albertosca/mead/commit/8288bbc). |

A arquitetura está em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (em inglês), e as decisões, com data, em [docs/superpowers/PROJECT-LOG.md](docs/superpowers/PROJECT-LOG.md).

## Início rápido

Você precisa de Elixir 1.20+ sobre Erlang/OTP 29.

```
git clone https://github.com/albertosca/mead.git
cd mead
mix deps.get
mix test
```

Abra uma sessão no `iex -S mix` (o handler padrão repete o texto, então não precisa de chave de API):

```elixir
{:ok, session_id} = Mead.start_session()
Mead.submit_turn(session_id, "hello")
#=> {:ok, "hello"}
```

Para rotear turnos de verdade, aponte o `Mead.Router` para um modelo em `config/config.exs`:

```elixir
config :mead, :turn_handler, Mead.Router

config :mead, :router,
  slots: [
    local: {Mead.Provider.Ollama, model: "llama3.1"},
    cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
  ]
```

Persistência, hub e servidor MCP e o endpoint do deck são ligados cada um pela própria chave `config :mead`; o [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) lista todas as opções.

## Parte de um sistema maior

O `mead` é o motor de um assistente pessoal: o `agent-swarm-deck` é o cliente Flutter que fala com ele pelo WebSocket do deck, e o `open-butler` guarda a lógica de domínio do assistente. Nenhum dos dois é necessário para rodar o `mead`.

## Contribuir e segurança

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) antes de abrir um pull request e o [SECURITY.md](SECURITY.md) para reportar uma vulnerabilidade em privado.

## Licença

MIT © Alberto Cavalcanti
