# Router e providers

O `Mead.Router` é um handler de turno sem estado: não tem processo, então nenhuma conversa divide um router com outra. Para cada turno ele escolhe um slot, chama o provider desse slot e emite um evento de telemetria `[:mead, :router, :route]` que o ledger conta.

## Escolhendo o slot

Force a rota por turno com `route: :local` ou `route: :cloud`. Sem isso, uma heurística classifica o turno:

* entrada com mais de 280 caracteres, histórico com mais de 20 turnos ou palavras de raciocínio vão para a nuvem;
* palavras de triagem e formatação vão para o modelo local;
* o resto vai para a nuvem.

Um turno roteado para um slot vazio falha com `:local_unavailable` ou `:cloud_unavailable`. Um turno local nunca vai para a nuvem por conta própria.

## Providers

| Provider | Slot | Notas |
|---|---|---|
| `Mead.Provider.Ollama` | local | Texto e ferramentas. O `:keep_alive` opcional mantém o modelo carregado entre turnos. |
| `Mead.Provider.Anthropic` | nuvem | Texto, streaming e ferramentas. |

Uma partida a frio do Ollama pode passar do timeout de recebimento de 25 segundos do provider, então use `:keep_alive` quando o primeiro turno importar.

## Ferramentas

Quando o provider escolhido aceita chamadas de ferramenta e a política mostra ao menos uma, o router roda um laço de até oito chamadas ao provider. Erros de ferramenta, negações e ferramentas desconhecidas voltam ao modelo como resultados de erro e nunca derrubam o turno. O laço roda dentro do timeout do turno, então uma conversa que usa ferramentas pode precisar de um `:turn_timeout` acima do padrão de 30 segundos.
