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

### Compactação e corte

Um arquivo é reescrito como um registro por turno ao retomar, quando passa de `compact_after_bytes` (padrão 1 MiB) e sob pedido por `Mead.compact_session/1`. A compactação guarda todos os turnos, a menos que você defina `max_turns`:

```elixir
config :mead, :storage, directory: "/var/lib/mead", max_turns: 200
```

Com `max_turns` definido, a compactação guarda só os turnos mais novos e os mais antigos se perdem. Fica desligado por padrão porque é a única opção que apaga conversa.

## Ledger

O `Mead.Ledger` conta tokens de entrada, tokens de saída, chamadas de ferramenta e latência por sessão e por rota, além dos últimos 100 turnos. Leia com `Mead.usage/1` ou pela ferramenta MCP `usage`.

Ele atualiza o ETS no processo que emitiu o evento e nunca levanta erro; um evento ilegível é contado como `dropped`. Um turno morto pelo timeout não emite evento e não é contado. Com um diretório de storage, o ledger tem journal em `ledger.journal` e é reproduzido no boot. Ele conta tokens, não dinheiro: orçamentos e preços não fazem parte dele.
