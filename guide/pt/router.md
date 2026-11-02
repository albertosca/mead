# Router e providers

O `Mead.Router` é um handler de turno sem estado: não tem processo, então nenhuma conversa divide um router com outra. Para cada turno ele escolhe um slot, chama o provider desse slot e emite um evento de telemetria `[:mead, :router, :route]` que o ledger conta.

## Escolhendo o slot

Force a rota por turno com `route: :local`, `route: :cloud` ou o nome de qualquer outro slot configurado (veja [Slots nomeados](#slots-nomeados)). Sem isso, uma heurística classifica o turno como local ou nuvem:

* entrada com mais de 280 caracteres, histórico com mais de 20 turnos ou palavras de raciocínio vão para a nuvem;
* palavras de triagem e formatação vão para o modelo local;
* o resto vai para a nuvem.

Um turno roteado para um slot vazio falha com `:local_unavailable`, `:cloud_unavailable` ou `{:slot_unavailable, nome}` para um slot nomeado. Um turno local nunca vai para a nuvem por conta própria.

## Slots nomeados

Além de `local` e `cloud`, a config do router aceita qualquer outro slot, e um turno chega a ele pelo nome. Isto roda o Gemma 2 ao lado do modelo local de sempre, escolhido por turno:

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
Mead.submit_turn(session_id, "Resuma isto em uma linha: ...", route: :gemma)
```

* As rotas válidas são `:auto`, `:local`, `:cloud` e cada outra chave de `slots`, lidas quando o turno é submetido; `Mead.Router.routes/0` lista todas. Qualquer outra rota dá `{:error, :invalid_route}`. Um slot chamado `auto` é ignorado.
* `route: :auto` continua escolhendo só entre `local` e `cloud`; um slot nomeado só é usado quando pedido.
* Um turno que um crash interrompeu continua no slot em que foi gravado. Se esse slot saiu da config nesse meio-tempo, o turno falha com `{:slot_unavailable, nome}` em vez de ir para outro modelo.
* Pelo MCP, a propriedade `route` do `submit_turn` lista os mesmos nomes, e um nome desconhecido é recusado sem nunca virar átomo.

`tool_use: false` desliga as ferramentas daquele slot: os turnos dele são completions simples mesmo com ferramentas MCP visíveis. O Gemma 2 precisa disso, porque o Ollama responde HTTP 400 ("does not support tools") a qualquer requisição com ferramentas, e sem a opção todo turno nesse slot falha com `:tools_unsupported` assim que houver uma ferramenta configurada. Qualquer valor que não seja `true` ou `false` falha o turno com `:invalid_slot`.

Gemma 2 2B medido num M1 de 8 GB: o primeiro turno depois de uma partida a frio levou 36 segundos (22,6 s carregando o modelo e 11,6 s lendo o prompt), acima do timeout de recebimento de 25 segundos do provider e do timeout de turno de 30 segundos. Daí o `keep_alive` para manter o modelo carregado entre turnos, `receive_timeout: 60_000` para o primeiro turno e um `turn_timeout` de 90 segundos na sessão.

## Providers

| Provider | Slot | Notas |
|---|---|---|
| `Mead.Provider.Ollama` | local, ou um slot nomeado | Texto e ferramentas. O `:keep_alive` opcional mantém o modelo carregado entre turnos. |
| `Mead.Provider.Anthropic` | nuvem | Texto, streaming e ferramentas. |

Uma partida a frio do Ollama pode passar do timeout de recebimento de 25 segundos do provider, então use `:keep_alive` quando o primeiro turno importar.

## Ferramentas

Quando o provider escolhido aceita chamadas de ferramenta, o slot dele não define `tool_use: false` e a política mostra ao menos uma, o router roda um laço de até oito chamadas ao provider. Erros de ferramenta, negações e ferramentas desconhecidas voltam ao modelo como resultados de erro e nunca derrubam o turno. O laço roda dentro do timeout do turno, então uma conversa que usa ferramentas pode precisar de um `:turn_timeout` acima do padrão de 30 segundos.
