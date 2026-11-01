# Persistência e ledger

## Persistência

A persistência vem desligada. Ligue com um diretório:

```elixir
config :mead, :storage, directory: "/var/lib/mead"
```

Cada sessão é um arquivo só de acréscimo, com o nome do seu id e um checksum em cada registro. `Mead.stop_session/1` guarda o arquivo, `Mead.resume_session/2` reconstrói a sessão a partir dele e `Mead.delete_session/1` o remove.

* Um turno que não pode ser gravado é recusado antes de o handler começar, então uma conversa nunca aceita um turno que esqueceria.
* Um registro cortado no fim do arquivo, que é o que uma queda deixa, é descartado com um aviso. Dano em qualquer outro ponto é `{:error, :corrupt_history}`.
* Os arquivos são privados (modo 0600). O diretório precisa ser confiável e ter um único escritor.

### Turnos duráveis

Todo turno sobrevive a uma queda do servidor da sessão, a um reinício do pool de sessões e à parada do nó inteiro. Um turno enviado sem `client_turn_id` ganha um gerado (`"mead-<uuid>"`, que aparece no histórico), e todo handler implementa `resume_turn/4`: o `Mead.start_session/1` recusa um que não implemente. Um handler sem nada para gravar como checkpoint retoma rodando o turno de novo.

* Cada passo de um turno roteado é gravado como checkpoint: a rota, cada resposta do modelo, cada chamada de ferramenta ao começar e ao terminar. Um turno continuado reproduz esses passos em vez de perguntar de novo.
* Uma chamada de ferramenta `:read` que estava rodando roda de novo. Uma chamada `:effect` que estava rodando nunca roda de novo: o modelo é avisado de que ela pode ou não ter tido efeito, para conferir antes de chamá-la outra vez.
* Uma sessão com turno em andamento deixa um marcador em `<diretório>/pending/`. O `Mead.Session.Keeper` retoma essas sessões no boot, então o turno continua sem ninguém pedir. Um desligamento ordenado suspende os turnos em andamento em vez de fazê-los falhar.
* A própria chamada espera o servidor da sessão reiniciar e devolve o desfecho do turno continuado; quem chamou nunca vê a queda, a menos que o servidor não volte em até 5 segundos depois dela. Mandar de novo a mesma chave e a mesma entrada junta-se ao turno em andamento ou devolve o resultado dele.
* Um turno cuja própria sessão continua falhando é continuado no máximo 3 vezes; depois disso termina `interrupted`, para que um turno que derruba quem o roda não entre em laço. Cortes causados por um reinício da infraestrutura em volta da sessão (o pool, o supervisor de turnos, o registry ou o nó) não contam para essas 3, só para um total de 20.
* Uma queda do supervisor de turnos ou do registry deixa o turno em andamento, e ele continua quando a árvore volta. O mesmo vale para uma rajada de falhas além dos 10 reinícios em 5 segundos do supervisor raiz: o `Mead.Watchdog` sobe a raiz de novo, com uma espera de 100 ms até 5 segundos, e quem chamou continua esperando pelo turno.
* Uma chamada `:effect` cancelada, que estourou o tempo, perdeu a conexão, recebeu uma resposta ilegível ou quebrou enquanto rodava é informada ao modelo como uma que pode ou não ter tido efeito.
* O diretório de todo arquivo novo é sincronizado, e todo evento do deck é sincronizado antes de um cliente recebê-lo, então uma queda de energia não perde nome de arquivo nem reaproveita número de sequência. No macOS a sincronização descarrega de fato o cache do disco (`F_FULLFSYNC`), e não só a barreira de ordem que o `:file.sync/1` do Erlang oferece ali.
* `Mead.stop_session/1` é definitivo: o turno em andamento termina `interrupted` e nunca é continuado. Um turno gravado por uma versão antiga, antes de os turnos guardarem suas opções, também termina `interrupted` depois de uma queda. Mandar de novo sem chave abre um turno novo; passe o seu próprio `client_turn_id` para se juntar ao que está rodando.

### Compactação e corte

Um arquivo é reescrito como um registro por turno ao retomar, quando passa de `compact_after_bytes` (padrão 1 MiB) e sob pedido por `Mead.compact_session/1`. A compactação guarda todos os turnos, a menos que você defina `max_turns`:

```elixir
config :mead, :storage, directory: "/var/lib/mead", max_turns: 200
```

Com `max_turns` definido, a compactação guarda só os turnos mais novos e os mais antigos se perdem. Fica desligado por padrão porque é a única opção que apaga conversa.

## Ledger

O `Mead.Ledger` conta tokens de entrada, tokens de saída, chamadas de ferramenta e latência por sessão e por rota, além dos últimos 100 turnos. Leia com `Mead.usage/1` ou pela ferramenta MCP `usage`.

Ele atualiza o ETS no processo que emitiu o evento e nunca levanta erro; um evento ilegível é contado como `dropped`. Um turno morto pelo timeout não emite evento e não é contado. Com um diretório de storage, o ledger tem journal em `ledger.journal` e é reproduzido no boot. Ele conta tokens, não dinheiro: orçamentos e preços não fazem parte dele.
